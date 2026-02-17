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
  private let maxConnectAttempts = 10
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
  var onContextCompacted: ((String) -> Void)?
  var onUndoStarted: ((String, String?) -> Void)?
  var onUndoCompleted: ((String, Bool, String?) -> Void)?
  var onThreadRolledBack: ((String, UInt32) -> Void)?
  var onSessionForked: ((String, String, String?) -> Void)? // sourceSessionId, newSessionId, forkedFromThreadId
  var onTurnDiffSnapshot: ((String, String, String, UInt64?, UInt64?, UInt64?, UInt64?)
    -> Void)? // sessionId, turnId, diff, inputTokens, outputTokens, cachedTokens, contextWindow
  var onReviewCommentCreated: ((String, ServerReviewComment) -> Void)?
  var onReviewCommentUpdated: ((String, ServerReviewComment) -> Void)?
  var onReviewCommentDeleted: ((String, String) -> Void)? // sessionId, commentId
  var onReviewCommentsList: ((String, [ServerReviewComment]) -> Void)?
  var onSubagentToolsList: ((String, String, [ServerSubagentTool]) -> Void)? // sessionId, subagentId, tools
  var onError: ((String, String, String?) -> Void)?
  var onConnected: (() -> Void)?
  var onDisconnected: (() -> Void)?

  /// Called when a replay event carries a revision number (for tracking last-seen revision)
  var onRevision: ((String, UInt64) -> Void)?

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
    configuration.timeoutIntervalForRequest = 5 // 5 second connect timeout
    configuration.timeoutIntervalForResource = 0 // No resource timeout (WebSocket is long-lived)
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

        // Exponential backoff capped at 10s: 1s, 2s, 4s, 8s, 10s, 10s, ...
        let delay = min(pow(2.0, Double(connectAttempts - 1)), 10.0)

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

        await MainActor.run {
          // Connection lost - try to reconnect (with limits)
          if case .connected = self.status {
            self.status = .disconnected
            self.onDisconnected?()
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

      case let .tokensUpdated(sessionId, usage):
        onTokensUpdated?(sessionId, usage)

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

      case let .turnDiffSnapshot(sessionId, turnId, diff, inputTokens, outputTokens, cachedTokens, contextWindow):
        onTurnDiffSnapshot?(sessionId, turnId, diff, inputTokens, outputTokens, cachedTokens, contextWindow)

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

      case let .error(code, errorMessage, sessionId):
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

  /// Subscribe to a specific session, optionally resuming from a known revision
  func subscribeSession(_ sessionId: String, sinceRevision: UInt64? = nil) {
    send(.subscribeSession(sessionId: sessionId, sinceRevision: sinceRevision))
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
    sandboxMode: String? = nil
  ) {
    send(.createSession(
      provider: provider,
      cwd: cwd,
      model: model,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode
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

  /// Set the OpenAI API key for AI session naming
  func setOpenAiKey(_ key: String) {
    send(.setOpenAiKey(key: key))
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

  /// Read Codex account/auth state.
  func readCodexAccount(refreshToken: Bool = false) {
    send(.codexAccountRead(refreshToken: refreshToken))
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
    send(.listSkills(sessionId: sessionId, cwds: cwds, forceReload: forceReload))
  }

  /// List remote skills available for download
  func listRemoteSkills(sessionId: String) {
    send(.listRemoteSkills(sessionId: sessionId))
  }

  /// Download a remote skill by hazelnut ID
  func downloadRemoteSkill(sessionId: String, hazelnutId: String) {
    send(.downloadRemoteSkill(sessionId: sessionId, hazelnutId: hazelnutId))
  }

  /// List MCP tools for a session
  func listMcpTools(sessionId: String) {
    send(.listMcpTools(sessionId: sessionId))
  }

  /// Refresh MCP servers for a session
  func refreshMcpServers(sessionId: String) {
    send(.refreshMcpServers(sessionId: sessionId))
  }

  /// Steer the active turn with additional guidance
  func steerTurn(sessionId: String, content: String) {
    send(.steerTurn(sessionId: sessionId, content: content))
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
    send(.listReviewComments(sessionId: sessionId, turnId: turnId))
  }

  /// Request subagent tools for a specific subagent
  func getSubagentTools(sessionId: String, subagentId: String) {
    send(.getSubagentTools(sessionId: sessionId, subagentId: subagentId))
  }

  /// Fork a session (creates a new session with conversation history)
  func forkSession(
    sourceSessionId: String,
    nthUserMessage: UInt32? = nil,
    model: String? = nil,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    cwd: String? = nil
  ) {
    send(.forkSession(
      sourceSessionId: sourceSessionId,
      nthUserMessage: nthUserMessage,
      model: model,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      cwd: cwd
    ))
  }
}
