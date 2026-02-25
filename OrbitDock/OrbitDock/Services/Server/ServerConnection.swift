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
  case failed(String) // Connection failed, not retrying
}

enum ServerRequestError: LocalizedError {
  case notConnected
  case connectionLost
  case invalidEndpoint
  case invalidResponse
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
      case .notConnected:
        "Server is not connected."
      case .connectionLost:
        "Server connection was lost before the request completed."
      case .invalidEndpoint:
        "Server endpoint URL is invalid."
      case .invalidResponse:
        "Server returned an invalid response."
      case let .httpStatus(status):
        "Server request failed with status \(status)."
    }
  }
}

private struct SessionSnapshotHTTPResponse: Decodable {
  let session: ServerSessionState
}

private struct SessionsListHTTPResponse: Decodable {
  let sessions: [ServerSessionSummary]
}

private struct ApprovalsHTTPResponse: Decodable {
  let sessionId: String?
  let approvals: [ServerApprovalHistoryItem]

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case approvals
  }
}

private struct DeleteApprovalHTTPResponse: Decodable {
  let approvalId: Int64
  let deleted: Bool

  enum CodingKeys: String, CodingKey {
    case approvalId = "approval_id"
    case deleted
  }
}

private struct OpenAiKeyHTTPResponse: Decodable {
  let configured: Bool
}

private struct CodexUsageHTTPResponse: Decodable {
  let usage: ServerCodexUsageSnapshot?
  let errorInfo: ServerUsageErrorInfo?

  enum CodingKeys: String, CodingKey {
    case usage
    case errorInfo = "error_info"
  }
}

private struct ClaudeUsageHTTPResponse: Decodable {
  let usage: ServerClaudeUsageSnapshot?
  let errorInfo: ServerUsageErrorInfo?

  enum CodingKeys: String, CodingKey {
    case usage
    case errorInfo = "error_info"
  }
}

private struct RecentProjectsHTTPResponse: Decodable {
  let projects: [ServerRecentProject]
}

private struct DirectoryListingHTTPResponse: Decodable {
  let path: String
  let entries: [ServerDirectoryEntry]
}

private struct CodexModelsHTTPResponse: Decodable {
  let models: [ServerCodexModelOption]
}

private struct ClaudeModelsHTTPResponse: Decodable {
  let models: [ServerClaudeModelOption]
}

private struct CodexAccountHTTPResponse: Decodable {
  let status: ServerCodexAccountStatus
}

private struct ReviewCommentsHTTPResponse: Decodable {
  let sessionId: String
  let comments: [ServerReviewComment]

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case comments
  }
}

private struct SubagentToolsHTTPResponse: Decodable {
  let sessionId: String
  let subagentId: String
  let tools: [ServerSubagentTool]

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case subagentId = "subagent_id"
    case tools
  }
}

private struct SkillsHTTPResponse: Decodable {
  let sessionId: String
  let skills: [ServerSkillsListEntry]
  let errors: [ServerSkillErrorInfo]

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case skills
    case errors
  }
}

private struct RemoteSkillsHTTPResponse: Decodable {
  let sessionId: String
  let skills: [ServerRemoteSkillSummary]

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case skills
  }
}

private struct McpToolsHTTPResponse: Decodable {
  let sessionId: String
  let tools: [String: ServerMcpTool]
  let resources: [String: [ServerMcpResource]]
  let resourceTemplates: [String: [ServerMcpResourceTemplate]]
  let authStatuses: [String: ServerMcpAuthStatus]

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case tools
    case resources
    case resourceTemplates = "resource_templates"
    case authStatuses = "auth_statuses"
  }
}

/// WebSocket connection to OrbitDock server
@MainActor
class ServerConnection: ObservableObject {
  /// Keep aligned with orbitdock-server WS_MAX_TEXT_MESSAGE_BYTES.
  private static let maxInboundWebSocketMessageBytes = 1 * 1_024 * 1_024

  let endpointId: UUID
  let endpointName: String

  @Published private(set) var status: ConnectionStatus = .disconnected
  @Published private(set) var lastError: String?
  @Published private(set) var serverIsPrimary: Bool?
  @Published private(set) var serverPrimaryClaims: [ServerClientPrimaryClaim] = []

  private var webSocket: URLSessionWebSocketTask?
  private var session: URLSession?
  private var receiveTask: Task<Void, Never>?
  private var connectTask: Task<Void, Never>?

  private var serverURL: URL
  private var connectAttempts = 0
  private var lastSentClientPrimaryClaim: (clientId: String, deviceName: String, isPrimary: Bool)?

  /// Whether we're connecting to a non-localhost server
  private var isRemote: Bool {
    guard let host = serverURL.host else { return false }
    return host != "127.0.0.1" && host != "localhost" && host != "::1"
  }

  /// Public read-only view of remote/local endpoint classification.
  var isRemoteConnection: Bool {
    isRemote
  }

  /// Remote gets more attempts since network can be flaky; local fails faster
  private var maxConnectAttempts: Int {
    isRemote ? 20 : 10
  }

  /// Remote uses longer max backoff (15s); local caps at 10s
  private var maxBackoffSeconds: Double {
    isRemote ? 15.0 : 10.0
  }

  /// Callbacks for received messages
  var onSessionsList: (([ServerSessionSummary]) -> Void)?
  var onSessionSnapshot: ((ServerSessionState) -> Void)?
  var onSessionDelta: ((String, ServerStateChanges) -> Void)?
  var onMessageAppended: ((String, ServerMessage) -> Void)?
  var onMessageUpdated: ((String, String, ServerMessageChanges) -> Void)?
  var onApprovalRequested: ((String, ServerApprovalRequest) -> Void)?
  var onTokensUpdated: ((String, ServerTokenUsage, ServerTokenUsageSnapshotKind) -> Void)?
  var onSessionCreated: ((ServerSessionSummary) -> Void)?
  var onSessionEnded: ((String, String) -> Void)?
  var onApprovalsList: ((String?, [ServerApprovalHistoryItem]) -> Void)?
  var onApprovalDeleted: ((Int64) -> Void)?
  var onModelsList: (([ServerCodexModelOption]) -> Void)?
  var onCodexAccountStatus: ((ServerCodexAccountStatus) -> Void)?
  var onCodexLoginChatgptStarted: ((String, String) -> Void)?
  var onCodexLoginChatgptCompleted: ((String, Bool, String?) -> Void)?
  var onCodexLoginChatgptCanceled: ((String, ServerCodexLoginCancelStatus) -> Void)?
  var onCodexAccountUpdated: ((ServerCodexAccountStatus) -> Void)?
  var onSkillsList: ((String, [ServerSkillsListEntry], [ServerSkillErrorInfo]) -> Void)?
  var onRemoteSkillsList: ((String, [ServerRemoteSkillSummary]) -> Void)?
  var onRemoteSkillDownloaded: ((String, String, String, String) -> Void)?
  var onSkillsUpdateAvailable: ((String) -> Void)?
  var onMcpToolsList: ((
    String,
    [String: ServerMcpTool],
    [String: [ServerMcpResource]],
    [String: [ServerMcpResourceTemplate]],
    [String: ServerMcpAuthStatus]
  ) -> Void)?
  var onMcpStartupUpdate: ((String, String, ServerMcpStartupStatus) -> Void)?
  var onMcpStartupComplete: ((String, [String], [ServerMcpStartupFailure], [String]) -> Void)?
  var onClaudeCapabilities: ((String, [String], [String], [String], [ServerClaudeModelOption]) -> Void)?
  var onClaudeModelsList: (([ServerClaudeModelOption]) -> Void)?
  var onContextCompacted: ((String) -> Void)?
  var onUndoStarted: ((String, String?) -> Void)?
  var onUndoCompleted: ((String, Bool, String?) -> Void)?
  var onThreadRolledBack: ((String, UInt32) -> Void)?
  var onSessionForked: ((String, String, String?) -> Void)? // sourceSessionId, newSessionId, forkedFromThreadId
  var onTurnDiffSnapshot: ((String, String, String, UInt64?, UInt64?, UInt64?, UInt64?, ServerTokenUsageSnapshotKind)
    -> Void)? // sessionId, turnId, diff, inputTokens, outputTokens, cachedTokens, contextWindow, snapshotKind
  var onReviewCommentCreated: ((String, ServerReviewComment) -> Void)?
  var onReviewCommentUpdated: ((String, ServerReviewComment) -> Void)?
  var onReviewCommentDeleted: ((String, String) -> Void)? // sessionId, commentId
  var onReviewCommentsList: ((String, [ServerReviewComment]) -> Void)?
  var onSubagentToolsList: ((String, String, [ServerSubagentTool]) -> Void)? // sessionId, subagentId, tools
  var onShellStarted: ((String, String, String) -> Void)? // sessionId, requestId, command
  var onShellOutput: ((String, String, String, String, Int32?, UInt64)
    -> Void)? // sessionId, requestId, stdout, stderr, exitCode, durationMs
  var onError: ((String, String, String?) -> Void)?
  var onConnected: (() -> Void)?
  var onDisconnected: (() -> Void)?

  /// Called when a replay event carries a revision number (for tracking last-seen revision)
  var onRevision: ((String, UInt64) -> Void)?

  init(endpoint: ServerEndpoint) {
    endpointId = endpoint.id
    endpointName = endpoint.name
    serverURL = endpoint.wsURL
  }

  // MARK: - Connection Lifecycle

  /// Connect to the runtime's current endpoint URL.
  func connect() {
    connect(to: serverURL)
  }

  /// Connect to a specific server URL
  func connect(to url: URL) {
    connLog(
      .info,
      category: .lifecycle,
      "connect(to:) called",
      data: ["url": url.absoluteString, "currentStatus": String(describing: status)]
    )
    switch status {
      case .disconnected, .failed:
        // OK to connect
        connectAttempts = 0
      case .connecting, .connected:
        logger.debug("Already connected or connecting")
        return
    }

    serverURL = url
    serverIsPrimary = nil
    serverPrimaryClaims = []
    lastSentClientPrimaryClaim = nil
    logger.info("Connecting to \(url.absoluteString)")
    attemptConnect()
  }

  private func attemptConnect() {
    guard connectAttempts < maxConnectAttempts else {
      let message = isRemote
        ? "Could not reach remote server after \(maxConnectAttempts) attempts"
        : "Failed to connect after \(maxConnectAttempts) attempts"
      status = .failed(message)
      lastError = message
      logger.error("Max connect attempts reached - giving up")
      return
    }

    connectAttempts += 1
    status = .connecting
    lastError = nil
    serverIsPrimary = nil
    serverPrimaryClaims = []
    lastSentClientPrimaryClaim = nil

    logger.info("Connecting to server (attempt \(self.connectAttempts)/\(self.maxConnectAttempts))...")

    // Clean up any previous connection
    receiveTask?.cancel()
    receiveTask = nil
    webSocket?.cancel()
    session?.invalidateAndCancel()

    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 5 // 5 second connect timeout
    configuration.timeoutIntervalForResource = 0 // No resource timeout (WebSocket is long-lived)
    session = URLSession(configuration: configuration)

    webSocket = session?.webSocketTask(with: serverURL)
    webSocket?.maximumMessageSize = Self.maxInboundWebSocketMessageBytes
    webSocket?.resume()
    startReceiving()

    // Verify connection with a ping
    connectTask = Task {
      do {
        try await ping()

        await MainActor.run {
          self.completeConnectionIfNeeded(trigger: "ping")
        }
      } catch {
        guard !Task.isCancelled else { return }

        let shouldRetry = await MainActor.run { () -> Bool in
          if case .connecting = self.status { return true }
          return false
        }
        guard shouldRetry else { return }

        logger.warning("Connect attempt \(self.connectAttempts) failed: \(error.localizedDescription)")

        // Exponential backoff: local caps at 10s, remote caps at 15s
        let delay = min(pow(2.0, Double(connectAttempts - 1)), maxBackoffSeconds)

        try? await Task.sleep(for: .seconds(delay))

        guard !Task.isCancelled else { return }

        await MainActor.run {
          self.attemptConnect()
        }
      }
    }
  }

  private func completeConnectionIfNeeded(trigger: String) {
    guard case .connecting = status else { return }

    if trigger != "ping" {
      connectTask?.cancel()
      connectTask = nil
    }

    status = .connected
    connectAttempts = 0
    logger.info("Connected to server")
    connLog(.info, category: .lifecycle, "status → connected", data: ["trigger": trigger])

    // Auto-subscribe to session list
    subscribeList()

    // Notify observers (e.g. to re-subscribe to sessions)
    onConnected?()
  }

  /// Disconnect from the server
  func disconnect() {
    failPendingRequests(with: ServerRequestError.connectionLost)

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
    serverIsPrimary = nil
    serverPrimaryClaims = []
    lastSentClientPrimaryClaim = nil
    onDisconnected?()
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
          connLog(.warning, category: .lifecycle, "Receive returned nil")

          await MainActor.run {
            switch self.status {
              case .connected, .connecting:
                self.failPendingRequests(with: ServerRequestError.connectionLost)
                self.status = .disconnected
                self.serverIsPrimary = nil
                self.serverPrimaryClaims = []
                self.lastSentClientPrimaryClaim = nil
                connLog(.info, category: .lifecycle, "status → disconnected (reconnecting)")
                self.onDisconnected?()
                self.attemptConnect()
              case .disconnected, .failed:
                break
            }
          }
          break
        }

        switch message {
          case let .string(text):
            handleMessage(text)
          case let .data(data):
            if let text = String(data: data, encoding: .utf8) {
              handleMessage(text)
            }
          @unknown default:
            break
        }
      } catch {
        logger.error("Receive error: \(error.localizedDescription)")
        connLog(
          .error,
          category: .lifecycle,
          "Receive error — reconnecting",
          data: ["error": error.localizedDescription]
        )

        await MainActor.run {
          switch self.status {
            case .connected, .connecting:
              self.failPendingRequests(with: ServerRequestError.connectionLost)
              self.status = .disconnected
              self.serverIsPrimary = nil
              self.serverPrimaryClaims = []
              self.lastSentClientPrimaryClaim = nil
              connLog(.info, category: .lifecycle, "status → disconnected (reconnecting)")
              self.onDisconnected?()
              self.attemptConnect()
            case .disconnected, .failed:
              break
          }
        }
        break
      }
    }
  }

  private func handleMessage(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    completeConnectionIfNeeded(trigger: "first_frame")

    do {
      let message = try JSONDecoder().decode(ServerToClientMessage.self, from: data)

      // Extract revision from replay events (server injects it at the top level)
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let rev = json["revision"] as? Int,
         let sid = json["session_id"] as? String
      {
        onRevision?(sid, UInt64(rev))
      }

      routeMessage(message)
    } catch {
      logger.error("Failed to decode message: \(error.localizedDescription)")
      logger.debug("Raw message: \(text.prefix(500))")
    }
  }

  private func routeMessage(_ message: ServerToClientMessage) {
    logger.info("Server message: \(String(describing: message).prefix(200))")

    switch message {
      case let .sessionsList(sessions):
        logger.info("Received sessions list: \(sessions.count) sessions")
        onSessionsList?(sessions)

      case let .sessionSnapshot(session):
        onSessionSnapshot?(session)

      case let .sessionDelta(sessionId, changes):
        onSessionDelta?(sessionId, changes)

      case let .messageAppended(sessionId, message):
        onMessageAppended?(sessionId, message)

      case let .messageUpdated(sessionId, messageId, changes):
        onMessageUpdated?(sessionId, messageId, changes)

      case let .approvalRequested(sessionId, request):
        onApprovalRequested?(sessionId, request)

      case let .tokensUpdated(sessionId, usage, snapshotKind):
        onTokensUpdated?(sessionId, usage, snapshotKind)

      case let .sessionCreated(session):
        onSessionCreated?(session)

      case let .sessionEnded(sessionId, reason):
        onSessionEnded?(sessionId, reason)

      case let .approvalsList(sessionId, approvals):
        onApprovalsList?(sessionId, approvals)

      case let .approvalDeleted(approvalId):
        onApprovalDeleted?(approvalId)

      case let .modelsList(models):
        onModelsList?(models)

      case let .codexAccountStatus(status):
        onCodexAccountStatus?(status)

      case let .codexLoginChatgptStarted(loginId, authUrl):
        onCodexLoginChatgptStarted?(loginId, authUrl)

      case let .codexLoginChatgptCompleted(loginId, success, error):
        onCodexLoginChatgptCompleted?(loginId, success, error)

      case let .codexLoginChatgptCanceled(loginId, status):
        onCodexLoginChatgptCanceled?(loginId, status)

      case let .codexAccountUpdated(status):
        onCodexAccountUpdated?(status)

      case let .skillsList(sessionId, skills, errors):
        onSkillsList?(sessionId, skills, errors)

      case let .remoteSkillsList(sessionId, skills):
        onRemoteSkillsList?(sessionId, skills)

      case let .remoteSkillDownloaded(sessionId, skillId, name, path):
        onRemoteSkillDownloaded?(sessionId, skillId, name, path)

      case let .skillsUpdateAvailable(sessionId):
        onSkillsUpdateAvailable?(sessionId)

      case let .mcpToolsList(sessionId, tools, resources, resourceTemplates, authStatuses):
        onMcpToolsList?(sessionId, tools, resources, resourceTemplates, authStatuses)

      case let .mcpStartupUpdate(sessionId, server, status):
        onMcpStartupUpdate?(sessionId, server, status)

      case let .mcpStartupComplete(sessionId, ready, failed, cancelled):
        onMcpStartupComplete?(sessionId, ready, failed, cancelled)

      case let .claudeCapabilities(sessionId, slashCommands, skills, tools, models):
        onClaudeCapabilities?(sessionId, slashCommands, skills, tools, models)

      case let .claudeModelsList(models):
        onClaudeModelsList?(models)

      case let .contextCompacted(sessionId):
        onContextCompacted?(sessionId)

      case let .undoStarted(sessionId, message):
        onUndoStarted?(sessionId, message)

      case let .undoCompleted(sessionId, success, message):
        onUndoCompleted?(sessionId, success, message)

      case let .threadRolledBack(sessionId, numTurns):
        onThreadRolledBack?(sessionId, numTurns)

      case let .sessionForked(sourceSessionId, newSessionId, forkedFromThreadId):
        onSessionForked?(sourceSessionId, newSessionId, forkedFromThreadId)

      case let .turnDiffSnapshot(
      sessionId,
      turnId,
      diff,
      inputTokens,
      outputTokens,
      cachedTokens,
      contextWindow,
      snapshotKind
    ):
        onTurnDiffSnapshot?(
          sessionId,
          turnId,
          diff,
          inputTokens,
          outputTokens,
          cachedTokens,
          contextWindow,
          snapshotKind
        )

      case let .reviewCommentCreated(sessionId, comment):
        onReviewCommentCreated?(sessionId, comment)

      case let .reviewCommentUpdated(sessionId, comment):
        onReviewCommentUpdated?(sessionId, comment)

      case let .reviewCommentDeleted(sessionId, commentId):
        onReviewCommentDeleted?(sessionId, commentId)

      case let .reviewCommentsList(sessionId, comments):
        onReviewCommentsList?(sessionId, comments)

      case let .subagentToolsList(sessionId, subagentId, tools):
        onSubagentToolsList?(sessionId, subagentId, tools)

      case let .shellStarted(sessionId, requestId, command):
        onShellStarted?(sessionId, requestId, command)

      case let .shellOutput(sessionId, requestId, stdout, stderr, exitCode, durationMs):
        onShellOutput?(sessionId, requestId, stdout, stderr, exitCode, durationMs)

      case .directoryListing, .recentProjectsList, .openAiKeyStatus, .codexUsageResult, .claudeUsageResult:
        break

      case let .serverInfo(isPrimary, clientPrimaryClaims):
        applyServerInfo(isPrimary: isPrimary, clientPrimaryClaims: clientPrimaryClaims)

      case let .error(code, errorMessage, sessionId):
        logger.error("Server error [\(code)]: \(errorMessage)")
        connLog(
          .error,
          category: .error,
          "Server error: [\(code)] \(errorMessage)",
          sessionId: sessionId
        )
        onError?(code, errorMessage, sessionId)
    }
  }

  func applyServerInfo(isPrimary: Bool, clientPrimaryClaims: [ServerClientPrimaryClaim] = []) {
    serverIsPrimary = isPrimary
    serverPrimaryClaims = clientPrimaryClaims
  }

  // MARK: - Sending Messages

  /// Send a message to the server
  func send(_ message: ClientToServerMessage) {
    let messageDesc = String(describing: message).prefix(200)
    guard case .connected = status else {
      connLog(
        .warning,
        category: .send,
        "BLOCKED — not connected",
        data: ["status": String(describing: status), "message": String(messageDesc)]
      )
      logger.warning("Cannot send - not connected")
      return
    }

    do {
      let data = try JSONEncoder().encode(message)
      guard let text = String(data: data, encoding: .utf8) else {
        connLog(.error, category: .send, "Failed to encode to UTF-8 string")
        return
      }

      connLog(
        .info,
        category: .send,
        "Sending \(text.count) bytes",
        data: ["type": String(messageDesc)]
      )

      webSocket?.send(.string(text)) { error in
        if let error {
          connLog(
            .error,
            category: .send,
            "WebSocket send error",
            data: ["error": error.localizedDescription]
          )
          logger.error("Send error: \(error.localizedDescription)")
        }
      }
    } catch {
      connLog(
        .error,
        category: .send,
        "Encode failed",
        data: ["error": error.localizedDescription]
      )
      logger.error("Failed to encode message: \(error.localizedDescription)")
    }
  }

  // MARK: - Convenience Methods

  /// Subscribe to the session list
  func subscribeList() {
    send(.subscribeList)
  }

  /// Subscribe to a specific session, optionally resuming from a known revision
  func subscribeSession(_ sessionId: String, sinceRevision: UInt64? = nil, includeSnapshot: Bool = true) {
    send(.subscribeSession(
      sessionId: sessionId,
      sinceRevision: sinceRevision,
      includeSnapshot: includeSnapshot
    ))
  }

  /// Unsubscribe from a session
  func unsubscribeSession(_ sessionId: String) {
    send(.unsubscribeSession(sessionId: sessionId))
  }

  /// Create a new session
  func createSession(
    provider: ServerProvider,
    cwd: String,
    model: String? = nil,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    permissionMode: String? = nil,
    allowedTools: [String] = [],
    disallowedTools: [String] = [],
    effort: String? = nil
  ) {
    send(.createSession(
      provider: provider,
      cwd: cwd,
      model: model,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      permissionMode: permissionMode,
      allowedTools: allowedTools,
      disallowedTools: disallowedTools,
      effort: effort
    ))
  }

  /// Send a message to a session with optional per-turn overrides, skills, images, and mentions
  func sendMessage(
    sessionId: String,
    content: String,
    model: String? = nil,
    effort: String? = nil,
    skills: [ServerSkillInput] = [],
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) {
    send(.sendMessage(
      sessionId: sessionId,
      content: content,
      model: model,
      effort: effort,
      skills: skills,
      images: images,
      mentions: mentions
    ))
  }

  /// Approve or reject a tool with a specific decision
  func approveTool(
    sessionId: String,
    requestId: String,
    decision: String,
    message: String? = nil,
    interrupt: Bool? = nil
  ) {
    send(.approveTool(
      sessionId: sessionId,
      requestId: requestId,
      decision: decision,
      message: message,
      interrupt: interrupt
    ))
  }

  /// Answer a question
  func answerQuestion(
    sessionId: String,
    requestId: String,
    answer: String,
    questionId: String? = nil,
    answers: [String: [String]]? = nil
  ) {
    send(.answerQuestion(
      sessionId: sessionId,
      requestId: requestId,
      answer: answer,
      questionId: questionId,
      answers: answers
    ))
  }

  /// Interrupt a session
  func interruptSession(_ sessionId: String) {
    send(.interruptSession(sessionId: sessionId))
  }

  /// End a session
  func endSession(_ sessionId: String) {
    send(.endSession(sessionId: sessionId))
  }

  /// Update session config (autonomy level change or permission mode change)
  func updateSessionConfig(
    sessionId: String,
    approvalPolicy: String?,
    sandboxMode: String?,
    permissionMode: String? = nil
  ) {
    send(.updateSessionConfig(
      sessionId: sessionId,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      permissionMode: permissionMode
    ))
  }

  /// Rename a session
  func renameSession(sessionId: String, name: String?) {
    send(.renameSession(sessionId: sessionId, name: name))
  }

  /// Update this server's runtime role for control-plane routing.
  func setServerRole(isPrimary: Bool) {
    send(.setServerRole(isPrimary: isPrimary))
  }

  /// Advertise whether this endpoint is the control-plane endpoint for the current client device.
  func setClientPrimaryClaim(clientId: String, deviceName: String, isPrimary: Bool) {
    guard case .connected = status else {
      return
    }

    if let previous = lastSentClientPrimaryClaim,
       previous.clientId == clientId,
       previous.deviceName == deviceName,
       previous.isPrimary == isPrimary
    {
      return
    }

    lastSentClientPrimaryClaim = (clientId: clientId, deviceName: deviceName, isPrimary: isPrimary)
    send(.setClientPrimaryClaim(clientId: clientId, deviceName: deviceName, isPrimary: isPrimary))
  }

  /// Set the OpenAI API key for AI session naming
  func setOpenAiKey(_ key: String) {
    send(.setOpenAiKey(key: key))
  }

  /// Request OpenAI key status for this endpoint as a one-shot response.
  func checkOpenAiKeyStatus() async throws -> Bool {
    let response: OpenAiKeyHTTPResponse = try await fetchAPIJSON(path: "/api/server/openai-key")
    return response.configured
  }

  /// Fetch full server session summaries over HTTP (bootstrap/read path).
  func fetchSessionsList() async throws -> [ServerSessionSummary] {
    let response: SessionsListHTTPResponse = try await fetchAPIJSON(path: "/api/sessions")
    return response.sessions
  }

  /// Fetch a full session snapshot over HTTP (bootstrap/read path).
  func fetchSessionSnapshot(_ sessionId: String) async throws -> ServerSessionState {
    let escapedSessionId = encodePathComponent(sessionId)
    let response: SessionSnapshotHTTPResponse = try await fetchAPIJSON(path: "/api/sessions/\(escapedSessionId)")
    return response.session
  }

  /// Fetch Codex rate-limit usage from this endpoint.
  func fetchCodexUsage() async throws -> (usage: ServerCodexUsageSnapshot?, errorInfo: ServerUsageErrorInfo?) {
    let response: CodexUsageHTTPResponse = try await fetchAPIJSON(path: "/api/usage/codex")
    return (usage: response.usage, errorInfo: response.errorInfo)
  }

  /// Fetch Claude subscription usage from this endpoint.
  func fetchClaudeUsage() async throws -> (usage: ServerClaudeUsageSnapshot?, errorInfo: ServerUsageErrorInfo?) {
    let response: ClaudeUsageHTTPResponse = try await fetchAPIJSON(path: "/api/usage/claude")
    return (usage: response.usage, errorInfo: response.errorInfo)
  }

  /// Request recent projects for this endpoint as a one-shot response.
  func listRecentProjects() async throws -> [ServerRecentProject] {
    let response: RecentProjectsHTTPResponse = try await fetchAPIJSON(path: "/api/fs/recent-projects")
    return response.projects
  }

  /// Request a directory listing as a one-shot response.
  func browseDirectory(path: String? = nil) async throws -> (path: String, entries: [ServerDirectoryEntry]) {
    var queryItems: [URLQueryItem] = []
    if let path, !path.isEmpty {
      queryItems.append(URLQueryItem(name: "path", value: path))
    }
    let response: DirectoryListingHTTPResponse = try await fetchAPIJSON(path: "/api/fs/browse", queryItems: queryItems)
    return (path: response.path, entries: response.entries)
  }

  /// Resume an ended session
  func resumeSession(_ sessionId: String) {
    connLog(.info, category: .resume, "resumeSession called", sessionId: sessionId)
    send(.resumeSession(sessionId: sessionId))
  }

  /// Take over a passive session (flip to direct mode)
  func takeoverSession(
    sessionId: String,
    model: String? = nil,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    permissionMode: String? = nil
  ) {
    send(.takeoverSession(
      sessionId: sessionId,
      model: model,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      permissionMode: permissionMode
    ))
  }

  /// Load approval history
  func listApprovals(sessionId: String?, limit: Int? = 200) {
    Task { @MainActor in
      do {
        var queryItems: [URLQueryItem] = []
        if let sessionId {
          queryItems.append(URLQueryItem(name: "session_id", value: sessionId))
        }
        if let limit {
          queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        let response: ApprovalsHTTPResponse = try await fetchAPIJSON(path: "/api/approvals", queryItems: queryItems)
        onApprovalsList?(response.sessionId ?? sessionId, response.approvals)
      } catch {
        onError?("approval_list_failed", error.localizedDescription, sessionId)
      }
    }
  }

  /// Delete one approval history row
  func deleteApproval(_ approvalId: Int64) {
    Task { @MainActor in
      do {
        let response: DeleteApprovalHTTPResponse =
          try await requestAPIJSON(path: "/api/approvals/\(approvalId)", method: "DELETE")
        if response.deleted {
          onApprovalDeleted?(response.approvalId)
        }
      } catch {
        onError?("approval_delete_failed", error.localizedDescription, nil)
      }
    }
  }

  /// Load codex model options discovered by the server
  func listModels() {
    Task { @MainActor in
      do {
        let response: CodexModelsHTTPResponse = try await fetchAPIJSON(path: "/api/models/codex")
        onModelsList?(response.models)
      } catch {
        onError?("model_list_failed", error.localizedDescription, nil)
      }
    }
  }

  /// Load cached Claude models from DB (populated when Claude sessions are created)
  func listClaudeModels() {
    Task { @MainActor in
      do {
        let response: ClaudeModelsHTTPResponse = try await fetchAPIJSON(path: "/api/models/claude")
        onClaudeModelsList?(response.models)
      } catch {
        onError?("claude_model_list_failed", error.localizedDescription, nil)
      }
    }
  }

  /// Read Codex account/auth state.
  func readCodexAccount(refreshToken: Bool = false) {
    Task { @MainActor in
      do {
        var queryItems: [URLQueryItem] = []
        if refreshToken {
          queryItems.append(URLQueryItem(name: "refresh_token", value: "true"))
        }
        let response: CodexAccountHTTPResponse =
          try await fetchAPIJSON(path: "/api/codex/account", queryItems: queryItems)
        onCodexAccountStatus?(response.status)
      } catch {
        onError?("codex_auth_error", error.localizedDescription, nil)
      }
    }
  }

  /// Start the ChatGPT browser login flow for Codex.
  func startCodexChatgptLogin() {
    send(.codexLoginChatgptStart)
  }

  /// Cancel an in-progress ChatGPT browser login flow.
  func cancelCodexChatgptLogin(loginId: String) {
    send(.codexLoginChatgptCancel(loginId: loginId))
  }

  /// Log out the current Codex account.
  func logoutCodexAccount() {
    send(.codexAccountLogout)
  }

  /// List skills available for a session
  func listSkills(sessionId: String, cwds: [String] = [], forceReload: Bool = false) {
    Task { @MainActor in
      do {
        let escapedSessionId = encodePathComponent(sessionId)
        var queryItems = cwds.map { URLQueryItem(name: "cwd", value: $0) }
        if forceReload {
          queryItems.append(URLQueryItem(name: "force_reload", value: "true"))
        }
        let response: SkillsHTTPResponse = try await fetchAPIJSON(
          path: "/api/sessions/\(escapedSessionId)/skills",
          queryItems: queryItems
        )
        onSkillsList?(response.sessionId, response.skills, response.errors)
      } catch {
        onError?("skills_list_failed", error.localizedDescription, sessionId)
      }
    }
  }

  /// List remote skills available for download
  func listRemoteSkills(sessionId: String) {
    Task { @MainActor in
      do {
        let escapedSessionId = encodePathComponent(sessionId)
        let response: RemoteSkillsHTTPResponse = try await fetchAPIJSON(
          path: "/api/sessions/\(escapedSessionId)/skills/remote"
        )
        onRemoteSkillsList?(response.sessionId, response.skills)
      } catch {
        onError?("remote_skills_list_failed", error.localizedDescription, sessionId)
      }
    }
  }

  /// Download a remote skill by hazelnut ID
  func downloadRemoteSkill(sessionId: String, hazelnutId: String) {
    send(.downloadRemoteSkill(sessionId: sessionId, hazelnutId: hazelnutId))
  }

  /// List MCP tools for a session
  func listMcpTools(sessionId: String) {
    Task { @MainActor in
      do {
        let escapedSessionId = encodePathComponent(sessionId)
        let response: McpToolsHTTPResponse = try await fetchAPIJSON(
          path: "/api/sessions/\(escapedSessionId)/mcp/tools"
        )
        onMcpToolsList?(
          response.sessionId,
          response.tools,
          response.resources,
          response.resourceTemplates,
          response.authStatuses
        )
      } catch {
        onError?("mcp_tools_list_failed", error.localizedDescription, sessionId)
      }
    }
  }

  /// Refresh MCP servers for a session
  func refreshMcpServers(sessionId: String) {
    send(.refreshMcpServers(sessionId: sessionId))
  }

  /// Steer the active turn with additional guidance
  func steerTurn(
    sessionId: String,
    content: String,
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) {
    send(.steerTurn(sessionId: sessionId, content: content, images: images, mentions: mentions))
  }

  /// Compact (summarize) the conversation context
  func compactContext(sessionId: String) {
    send(.compactContext(sessionId: sessionId))
  }

  /// Undo the last turn (reverts filesystem changes + removes from context)
  func undoLastTurn(sessionId: String) {
    send(.undoLastTurn(sessionId: sessionId))
  }

  /// Roll back N turns from context (does NOT revert filesystem changes)
  func rollbackTurns(sessionId: String, numTurns: UInt32) {
    send(.rollbackTurns(sessionId: sessionId, numTurns: numTurns))
  }

  /// Create a review comment
  func createReviewComment(
    sessionId: String,
    turnId: String?,
    filePath: String,
    lineStart: UInt32,
    lineEnd: UInt32?,
    body: String,
    tag: ServerReviewCommentTag?
  ) {
    send(.createReviewComment(
      sessionId: sessionId,
      turnId: turnId,
      filePath: filePath,
      lineStart: lineStart,
      lineEnd: lineEnd,
      body: body,
      tag: tag
    ))
  }

  /// Update a review comment
  func updateReviewComment(
    commentId: String,
    body: String?,
    tag: ServerReviewCommentTag?,
    status: ServerReviewCommentStatus?
  ) {
    send(.updateReviewComment(commentId: commentId, body: body, tag: tag, status: status))
  }

  /// Delete a review comment
  func deleteReviewComment(commentId: String) {
    send(.deleteReviewComment(commentId: commentId))
  }

  /// List review comments for a session
  func listReviewComments(sessionId: String, turnId: String? = nil) {
    Task { @MainActor in
      do {
        let escapedSessionId = encodePathComponent(sessionId)
        var queryItems: [URLQueryItem] = []
        if let turnId {
          queryItems.append(URLQueryItem(name: "turn_id", value: turnId))
        }

        let response: ReviewCommentsHTTPResponse = try await fetchAPIJSON(
          path: "/api/sessions/\(escapedSessionId)/review-comments",
          queryItems: queryItems
        )
        onReviewCommentsList?(response.sessionId, response.comments)
      } catch {
        onError?("review_comments_list_failed", error.localizedDescription, sessionId)
      }
    }
  }

  /// Request subagent tools for a specific subagent
  func getSubagentTools(sessionId: String, subagentId: String) {
    Task { @MainActor in
      do {
        let escapedSessionId = encodePathComponent(sessionId)
        let escapedSubagentId = encodePathComponent(subagentId)
        let response: SubagentToolsHTTPResponse = try await fetchAPIJSON(
          path: "/api/sessions/\(escapedSessionId)/subagents/\(escapedSubagentId)/tools"
        )
        onSubagentToolsList?(response.sessionId, response.subagentId, response.tools)
      } catch {
        onError?("subagent_tools_failed", error.localizedDescription, sessionId)
      }
    }
  }

  /// Execute a shell command in a session's working directory
  func executeShell(sessionId: String, command: String, cwd: String? = nil, timeout: UInt64 = 30) {
    send(.executeShell(sessionId: sessionId, command: command, cwd: cwd, timeoutSecs: timeout))
  }

  /// Fork a session (creates a new session with conversation history)
  func forkSession(
    sourceSessionId: String,
    nthUserMessage: UInt32? = nil,
    model: String? = nil,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    cwd: String? = nil,
    permissionMode: String? = nil,
    allowedTools: [String] = [],
    disallowedTools: [String] = []
  ) {
    send(.forkSession(
      sourceSessionId: sourceSessionId,
      nthUserMessage: nthUserMessage,
      model: model,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      cwd: cwd,
      permissionMode: permissionMode,
      allowedTools: allowedTools,
      disallowedTools: disallowedTools
    ))
  }

  private func failPendingRequests(with error: Error) {
    _ = error
  }

  private func requestAPIJSON<Response: Decodable>(
    path: String,
    method: String,
    queryItems: [URLQueryItem] = []
  ) async throws -> Response {
    guard let url = apiURL(path: path, queryItems: queryItems) else {
      throw ServerRequestError.invalidEndpoint
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ServerRequestError.invalidResponse
    }
    guard (200 ..< 300).contains(http.statusCode) else {
      throw ServerRequestError.httpStatus(http.statusCode)
    }
    return try JSONDecoder().decode(Response.self, from: data)
  }

  private func fetchAPIJSON<Response: Decodable>(
    path: String,
    queryItems: [URLQueryItem] = []
  ) async throws -> Response {
    try await requestAPIJSON(path: path, method: "GET", queryItems: queryItems)
  }

  private func encodePathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  private func apiURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
    guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
      return nil
    }

    if components.scheme == "wss" {
      components.scheme = "https"
    } else {
      components.scheme = "http"
    }

    var basePath = components.path
    if basePath.hasSuffix("/ws") {
      basePath = String(basePath.dropLast(3))
    }

    let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
    if basePath.isEmpty || basePath == "/" {
      components.path = normalizedPath
    } else {
      if basePath.hasSuffix("/") {
        basePath.removeLast()
      }
      components.path = "\(basePath)\(normalizedPath)"
    }

    components.queryItems = queryItems.isEmpty ? nil : queryItems
    return components.url
  }
}
