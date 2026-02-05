//
//  ServerConnection.swift
//  OrbitDock
//
//  WebSocket client for the OrbitDock Rust server.
//  Handles connection lifecycle, message routing, and reconnection.
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
  case reconnecting(attempt: Int)
}

/// WebSocket connection to OrbitDock server
@MainActor
final class ServerConnection: ObservableObject {
  static let shared = ServerConnection()

  @Published private(set) var status: ConnectionStatus = .disconnected
  @Published private(set) var lastError: String?

  private var webSocket: URLSessionWebSocketTask?
  private var session: URLSession?
  private var reconnectTask: Task<Void, Never>?
  private var receiveTask: Task<Void, Never>?

  private let serverURL = URL(string: "ws://127.0.0.1:4000/ws")!
  private let maxReconnectAttempts = 5
  private let reconnectDelay: TimeInterval = 2.0

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
  var onError: ((String, String, String?) -> Void)?

  private init() {}

  // MARK: - Connection Lifecycle

  /// Connect to the server
  func connect() {
    guard status == .disconnected else {
      logger.debug("Already connected or connecting")
      return
    }

    status = .connecting
    lastError = nil

    let configuration = URLSessionConfiguration.default
    configuration.waitsForConnectivity = true
    session = URLSession(configuration: configuration)

    webSocket = session?.webSocketTask(with: serverURL)
    webSocket?.resume()

    status = .connected
    logger.info("Connected to server")

    startReceiving()
  }

  /// Disconnect from the server
  func disconnect() {
    reconnectTask?.cancel()
    reconnectTask = nil
    receiveTask?.cancel()
    receiveTask = nil

    webSocket?.cancel(with: .goingAway, reason: nil)
    webSocket = nil
    session?.invalidateAndCancel()
    session = nil

    status = .disconnected
    logger.info("Disconnected from server")
  }

  /// Reconnect with exponential backoff
  private func scheduleReconnect(attempt: Int) {
    guard attempt < maxReconnectAttempts else {
      logger.error("Max reconnect attempts reached")
      status = .disconnected
      lastError = "Failed to reconnect after \(maxReconnectAttempts) attempts"
      return
    }

    status = .reconnecting(attempt: attempt + 1)
    let delay = reconnectDelay * Double(attempt + 1)

    reconnectTask = Task {
      try? await Task.sleep(for: .seconds(delay))

      guard !Task.isCancelled else { return }

      logger.info("Reconnecting (attempt \(attempt + 1))...")
      webSocket?.cancel()

      webSocket = session?.webSocketTask(with: serverURL)
      webSocket?.resume()

      // Check if connected
      do {
        try await ping()
        await MainActor.run {
          self.status = .connected
          self.startReceiving()
        }
        logger.info("Reconnected successfully")
      } catch {
        await MainActor.run {
          self.scheduleReconnect(attempt: attempt + 1)
        }
      }
    }
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
          if self.status == .connected {
            self.scheduleReconnect(attempt: 0)
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
    switch message {
    case .sessionsList(let sessions):
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

    case .error(let code, let errorMessage, let sessionId):
      logger.error("Server error [\(code)]: \(errorMessage)")
      onError?(code, errorMessage, sessionId)
    }
  }

  // MARK: - Sending Messages

  /// Send a message to the server
  func send(_ message: ClientToServerMessage) {
    guard status == .connected else {
      logger.warning("Cannot send - not connected")
      return
    }

    do {
      let data = try JSONEncoder().encode(message)
      guard let text = String(data: data, encoding: .utf8) else { return }

      webSocket?.send(.string(text)) { [weak self] error in
        if let error {
          logger.error("Send error: \(error.localizedDescription)")
          Task { @MainActor in
            self?.scheduleReconnect(attempt: 0)
          }
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
  func createSession(provider: ServerProvider, cwd: String, model: String? = nil) {
    send(.createSession(provider: provider, cwd: cwd, model: model))
  }

  /// Send a message to a session
  func sendMessage(sessionId: String, content: String) {
    send(.sendMessage(sessionId: sessionId, content: content))
  }

  /// Approve or reject a tool
  func approveTool(sessionId: String, requestId: String, approved: Bool) {
    send(.approveTool(sessionId: sessionId, requestId: requestId, approved: approved))
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
}
