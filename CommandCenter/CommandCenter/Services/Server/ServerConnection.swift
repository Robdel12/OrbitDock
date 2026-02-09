//
//  ServerConnection.swift
//  OrbitDock
//
//  WebSocket client for the OrbitDock Rust server.
//  Handles connection lifecycle with LIMITED reconnection attempts.
//  After max attempts, stops trying - user must manually reconnect.
//

import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "server-connection")

/// Connection status
enum ConnectionStatus: Equatable {
  case disconnected
  case connecting
  case connected
  case failed(String)  // Connection failed, not retrying
}

/// WebSocket connection to OrbitDock server
@MainActor
final class ServerConnection: ObservableObject {
  static let shared = ServerConnection()

  @Published private(set) var status: ConnectionStatus = .disconnected
  @Published private(set) var lastError: String?

  private var webSocket: URLSessionWebSocketTask?
  private var session: URLSession?
  private var receiveTask: Task<Void, Never>?
  private var connectTask: Task<Void, Never>?

  private let serverURL = URL(string: "ws://127.0.0.1:4000/ws")!
  private let maxConnectAttempts = 3
  private var connectAttempts = 0

  /// Callbacks for received messages
  var onSessionsList: (([ServerSessionSummary]) -> Void)?
  var onSessionSnapshot: ((ServerSessionState) -> Void)?
  var onSessionDelta: ((String, ServerStateChanges) -> Void)?
  var onMessageAppended: ((String, ServerMessage) -> Void)?
  var onMessageUpdated: ((String, String, ServerMessageChanges) -> Void)?
  var onApprovalRequested: ((String, ServerApprovalRequest) -> Void)?
  var onTokensUpdated: ((String, ServerTokenUsage) -> Void)?
  var onSessionCreated: ((ServerSessionSummary) -> Void)?
  var onSessionEnded: ((String, String) -> Void)?
  var onApprovalsList: ((String?, [ServerApprovalHistoryItem]) -> Void)?
  var onApprovalDeleted: ((Int64) -> Void)?
  var onModelsList: (([ServerCodexModelOption]) -> Void)?
  var onError: ((String, String, String?) -> Void)?
  var onConnected: (() -> Void)?

  private init() {}

  // MARK: - Connection Lifecycle

  /// Connect to the server (retries up to maxConnectAttempts, then gives up)
  func connect() {
    switch status {
    case .disconnected, .failed:
      // OK to connect
      connectAttempts = 0
    case .connecting, .connected:
      logger.debug("Already connected or connecting")
      return
    }

    attemptConnect()
  }

  private func attemptConnect() {
    guard connectAttempts < maxConnectAttempts else {
      status = .failed("Failed to connect after \(maxConnectAttempts) attempts")
      lastError = "Server unavailable"
      logger.error("Max connect attempts reached - giving up")
      return
    }

    connectAttempts += 1
    status = .connecting
    lastError = nil

    logger.info("Connecting to server (attempt \(self.connectAttempts)/\(self.maxConnectAttempts))...")

    // Clean up any previous connection
    webSocket?.cancel()
    session?.invalidateAndCancel()

    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 5  // 5 second connect timeout
    configuration.timeoutIntervalForResource = 0  // No resource timeout (WebSocket is long-lived)
    session = URLSession(configuration: configuration)

    webSocket = session?.webSocketTask(with: serverURL)
    webSocket?.resume()

    // Verify connection with a ping
    connectTask = Task {
      do {
        try await ping()

        await MainActor.run {
          self.status = .connected
          self.connectAttempts = 0
          logger.info("Connected to server")
          self.startReceiving()

          // Auto-subscribe to session list
          self.subscribeList()

          // Notify observers (e.g. to re-subscribe to sessions)
          self.onConnected?()
        }
      } catch {
        logger.warning("Connect attempt \(self.connectAttempts) failed: \(error.localizedDescription)")

        // Exponential backoff: 1s, 2s, 4s
        let delay = pow(2.0, Double(connectAttempts - 1))

        try? await Task.sleep(for: .seconds(delay))

        guard !Task.isCancelled else { return }

        await MainActor.run {
          self.attemptConnect()
        }
      }
    }
  }

  /// Disconnect from the server
  func disconnect() {
    connectTask?.cancel()
    connectTask = nil
    receiveTask?.cancel()
    receiveTask = nil

    webSocket?.cancel(with: .goingAway, reason: nil)
    webSocket = nil
    session?.invalidateAndCancel()
    session = nil

    connectAttempts = 0
    status = .disconnected
    logger.info("Disconnected from server")
  }

  private func ping() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      webSocket?.sendPing { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  // MARK: - Receiving Messages

  private func startReceiving() {
    receiveTask = Task {
      await receiveLoop()
    }
  }

  private func receiveLoop() async {
    while !Task.isCancelled {
      do {
        guard let message = try await webSocket?.receive() else {
          break
        }

        switch message {
        case .string(let text):
          handleMessage(text)
        case .data(let data):
          if let text = String(data: data, encoding: .utf8) {
            handleMessage(text)
          }
        @unknown default:
          break
        }
      } catch {
        logger.error("Receive error: \(error.localizedDescription)")

        await MainActor.run {
          // Connection lost - try to reconnect (with limits)
          if case .connected = self.status {
            self.status = .disconnected
            self.attemptConnect()
          }
        }
        break
      }
    }
  }

  private func handleMessage(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }

    do {
      let message = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
      routeMessage(message)
    } catch {
      logger.error("Failed to decode message: \(error.localizedDescription)")
      logger.debug("Raw message: \(text.prefix(500))")
    }
  }

  private func routeMessage(_ message: ServerToClientMessage) {
    logger.info("Server message: \(String(describing: message).prefix(200))")

    switch message {
    case .sessionsList(let sessions):
      logger.info("Received sessions list: \(sessions.count) sessions")
      onSessionsList?(sessions)

    case .sessionSnapshot(let session):
      onSessionSnapshot?(session)

    case .sessionDelta(let sessionId, let changes):
      onSessionDelta?(sessionId, changes)

    case .messageAppended(let sessionId, let message):
      onMessageAppended?(sessionId, message)

    case .messageUpdated(let sessionId, let messageId, let changes):
      onMessageUpdated?(sessionId, messageId, changes)

    case .approvalRequested(let sessionId, let request):
      onApprovalRequested?(sessionId, request)

    case .tokensUpdated(let sessionId, let usage):
      onTokensUpdated?(sessionId, usage)

    case .sessionCreated(let session):
      onSessionCreated?(session)

    case .sessionEnded(let sessionId, let reason):
      onSessionEnded?(sessionId, reason)

    case .approvalsList(let sessionId, let approvals):
      onApprovalsList?(sessionId, approvals)

    case .approvalDeleted(let approvalId):
      onApprovalDeleted?(approvalId)

    case .modelsList(let models):
      onModelsList?(models)

    case .error(let code, let errorMessage, let sessionId):
      logger.error("Server error [\(code)]: \(errorMessage)")
      onError?(code, errorMessage, sessionId)
    }
  }

  // MARK: - Sending Messages

  /// Send a message to the server
  func send(_ message: ClientToServerMessage) {
    guard case .connected = status else {
      logger.warning("Cannot send - not connected")
      return
    }

    do {
      let data = try JSONEncoder().encode(message)
      guard let text = String(data: data, encoding: .utf8) else { return }

      webSocket?.send(.string(text)) { error in
        if let error {
          logger.error("Send error: \(error.localizedDescription)")
          // Don't auto-reconnect on send errors - let receiveLoop handle it
        }
      }
    } catch {
      logger.error("Failed to encode message: \(error.localizedDescription)")
    }
  }

  // MARK: - Convenience Methods

  /// Subscribe to the session list
  func subscribeList() {
    send(.subscribeList)
  }

  /// Subscribe to a specific session
  func subscribeSession(_ sessionId: String) {
    send(.subscribeSession(sessionId: sessionId))
  }

  /// Unsubscribe from a session
  func unsubscribeSession(_ sessionId: String) {
    send(.unsubscribeSession(sessionId: sessionId))
  }

  /// Create a new session
  func createSession(provider: ServerProvider, cwd: String, model: String? = nil, approvalPolicy: String? = nil, sandboxMode: String? = nil) {
    send(.createSession(provider: provider, cwd: cwd, model: model, approvalPolicy: approvalPolicy, sandboxMode: sandboxMode))
  }

  /// Send a message to a session with optional per-turn overrides
  func sendMessage(sessionId: String, content: String, model: String? = nil, effort: String? = nil) {
    send(.sendMessage(sessionId: sessionId, content: content, model: model, effort: effort))
  }

  /// Approve or reject a tool with a specific decision
  func approveTool(sessionId: String, requestId: String, decision: String) {
    send(.approveTool(sessionId: sessionId, requestId: requestId, decision: decision))
  }

  /// Answer a question
  func answerQuestion(sessionId: String, requestId: String, answer: String) {
    send(.answerQuestion(sessionId: sessionId, requestId: requestId, answer: answer))
  }

  /// Interrupt a session
  func interruptSession(_ sessionId: String) {
    send(.interruptSession(sessionId: sessionId))
  }

  /// End a session
  func endSession(_ sessionId: String) {
    send(.endSession(sessionId: sessionId))
  }

  /// Update session config (autonomy level change)
  func updateSessionConfig(sessionId: String, approvalPolicy: String?, sandboxMode: String?) {
    send(.updateSessionConfig(sessionId: sessionId, approvalPolicy: approvalPolicy, sandboxMode: sandboxMode))
  }

  /// Rename a session
  func renameSession(sessionId: String, name: String?) {
    send(.renameSession(sessionId: sessionId, name: name))
  }

  /// Resume an ended session
  func resumeSession(_ sessionId: String) {
    send(.resumeSession(sessionId: sessionId))
  }

  /// Load approval history
  func listApprovals(sessionId: String?, limit: Int? = 200) {
    send(.listApprovals(sessionId: sessionId, limit: limit))
  }

  /// Delete one approval history row
  func deleteApproval(_ approvalId: Int64) {
    send(.deleteApproval(approvalId: approvalId))
  }

  /// Load codex model options discovered by the server
  func listModels() {
    send(.listModels)
  }
}
