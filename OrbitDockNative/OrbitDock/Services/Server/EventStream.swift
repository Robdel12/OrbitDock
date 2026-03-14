import Foundation

/// Decoded server push event, typed and ready for consumption.
/// Reuses the existing ServerToClientMessage decode pipeline.
enum ServerEvent: Sendable {
  // Session list
  case sessionsList([ServerSessionListItem])
  case sessionCreated(ServerSessionListItem)
  case sessionListItemUpdated(ServerSessionListItem)
  case sessionListItemRemoved(sessionId: String)
  case sessionEnded(sessionId: String, reason: String)

  // Session state
  case conversationBootstrap(session: ServerSessionState, conversation: ServerConversationHistoryPage)
  case sessionSnapshot(ServerSessionState)
  case sessionDelta(sessionId: String, changes: ServerStateChanges)

  // Messages
  case conversationRowsChanged(
    sessionId: String,
    upserted: [ServerConversationRowEntry],
    removedRowIds: [String],
    totalRowCount: UInt64?
  )

  // Approvals
  case approvalRequested(sessionId: String, request: ServerApprovalRequest, approvalVersion: UInt64?)
  case approvalDecisionResult(
    sessionId: String, requestId: String, outcome: String,
    activeRequestId: String?, approvalVersion: UInt64)
  case approvalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem])
  case approvalDeleted(approvalId: Int64)

  // Tokens
  case tokensUpdated(
    sessionId: String, usage: ServerTokenUsage, snapshotKind: ServerTokenUsageSnapshotKind)

  // Models / Codex account
  case modelsList([ServerCodexModelOption])
  case claudeModelsList([ServerClaudeModelOption])
  case codexAccountStatus(ServerCodexAccountStatus)
  case codexLoginChatgptStarted(loginId: String, authUrl: String)
  case codexLoginChatgptCompleted(loginId: String, success: Bool, error: String?)
  case codexLoginChatgptCanceled(loginId: String, status: ServerCodexLoginCancelStatus)
  case codexAccountUpdated(ServerCodexAccountStatus)

  // Skills
  case skillsList(sessionId: String, skills: [ServerSkillsListEntry], errors: [ServerSkillErrorInfo])
  case remoteSkillsList(sessionId: String, skills: [ServerRemoteSkillSummary])
  case remoteSkillDownloaded(sessionId: String, skillId: String, name: String, path: String)
  case skillsUpdateAvailable(sessionId: String)

  // MCP
  case mcpToolsList(
    sessionId: String, tools: [String: ServerMcpTool],
    resources: [String: [ServerMcpResource]],
    resourceTemplates: [String: [ServerMcpResourceTemplate]],
    authStatuses: [String: ServerMcpAuthStatus])
  case mcpStartupUpdate(sessionId: String, server: String, status: ServerMcpStartupStatus)
  case mcpStartupComplete(
    sessionId: String, ready: [String], failed: [ServerMcpStartupFailure],
    cancelled: [String])

  // Claude capabilities
  case claudeCapabilities(
    sessionId: String, slashCommands: [String], skills: [String],
    tools: [String], models: [ServerClaudeModelOption])

  // Context / undo / fork
  case contextCompacted(sessionId: String)
  case undoStarted(sessionId: String, message: String?)
  case undoCompleted(sessionId: String, success: Bool, message: String?)
  case threadRolledBack(sessionId: String, numTurns: UInt32)
  case sessionForked(sourceSessionId: String, newSessionId: String, forkedFromThreadId: String?)

  // Turn diffs
  case turnDiffSnapshot(
    sessionId: String, turnId: String, diff: String,
    inputTokens: UInt64?, outputTokens: UInt64?, cachedTokens: UInt64?,
    contextWindow: UInt64?, snapshotKind: ServerTokenUsageSnapshotKind)

  // Review comments
  case reviewCommentCreated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentUpdated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentDeleted(sessionId: String, reviewRevision: UInt64, commentId: String)
  case reviewCommentsList(sessionId: String, reviewRevision: UInt64, comments: [ServerReviewComment])

  // Subagent
  case subagentToolsList(sessionId: String, subagentId: String, tools: [ServerSubagentTool])

  // Shell
  case shellStarted(sessionId: String, requestId: String, command: String)
  case shellOutput(
    sessionId: String, requestId: String, stdout: String, stderr: String,
    exitCode: Int32?, durationMs: UInt64, outcome: ServerShellExecutionOutcome)

  // Worktrees
  case worktreesList(requestId: String, repoRoot: String?, worktreeRevision: UInt64, worktrees: [ServerWorktreeSummary])
  case worktreeCreated(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktree: ServerWorktreeSummary)
  case worktreeRemoved(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktreeId: String)
  case worktreeStatusChanged(worktreeId: String, status: ServerWorktreeStatus, repoRoot: String)
  case worktreeError(requestId: String, code: String, message: String)

  // Rate limit
  case rateLimitEvent(sessionId: String, info: ServerRateLimitInfo)

  // Misc
  case promptSuggestion(sessionId: String, suggestion: String)
  case filesPersisted(sessionId: String, files: [String])
  case serverInfo(isPrimary: Bool, claims: [ServerClientPrimaryClaim])

  // Error
  case error(code: String, message: String, sessionId: String?)

  // Permission rules
  case permissionRules(sessionId: String, rules: ServerSessionPermissionRules)

  // Connection lifecycle
  case connectionStatusChanged(ConnectionStatus)

  // Revision tracking
  case revision(sessionId: String, revision: UInt64)
}

// MARK: - EventStream

/// Single WebSocket connection to one OrbitDock server.
/// Produces events via callback. Handles reconnection with exponential backoff.
/// Only 3 outbound messages: subscribeList, subscribeSession, unsubscribeSession.
@MainActor
final class EventStream {
  private(set) var connectionStatus: ConnectionStatus = .disconnected
  private(set) var latestSessionListItems: [ServerSessionListItem] = []
  private(set) var hasReceivedInitialSessionsList = false

  /// Event listeners. Multiple consumers can register.
  var onEvent: ((ServerEvent) -> Void)?
  private var additionalListeners: [(ServerEvent) -> Void] = []

  func addListener(_ listener: @escaping (ServerEvent) -> Void) {
    additionalListeners.append(listener)
  }

  private let authToken: String?
  private var serverURL: URL?
  private var webSocket: URLSessionWebSocketTask?
  private var urlSession: URLSession?
  private var receiveTask: Task<Void, Never>?
  private var connectTask: Task<Void, Never>?
  private var keepAliveTask: Task<Void, Never>?
  private var connectAttempts = 0
  private var lastConnectedAt: Date?

  private static let maxInboundBytes = 8 * 1_024 * 1_024
  private static let stableConnectionThreshold: TimeInterval = 30
  private static let keepAliveInterval: TimeInterval = 30

  var isRemote: Bool {
    guard let host = serverURL?.host else { return false }
    return host != "127.0.0.1" && host != "localhost" && host != "::1"
  }

  private var maxConnectAttempts: Int { isRemote ? 20 : 10 }
  private var maxBackoffSeconds: Double { isRemote ? 15.0 : 10.0 }

  init(authToken: String?) {
    self.authToken = authToken
  }

  // MARK: - Connection

  func connect(to url: URL) {
    switch connectionStatus {
    case .disconnected, .failed:
      connectAttempts = 0
    case .connecting, .connected:
      return
    }
    serverURL = url
    attemptConnect()
  }

  func reconnectIfNeeded() {
    guard serverURL != nil else { return }
    switch connectionStatus {
    case .connected, .connecting:
      Task {
        do { try await ping() }
        catch { handleDisconnect() }
      }
    case .disconnected, .failed:
      connectAttempts = 0
      attemptConnect()
    }
  }

  func disconnect() {
    stopKeepAlive()
    connectTask?.cancel()
    connectTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    webSocket?.cancel(with: .goingAway, reason: nil)
    webSocket = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    connectAttempts = 0
    lastConnectedAt = nil
    latestSessionListItems = []
    hasReceivedInitialSessionsList = false
    setStatus(.disconnected)
  }

  // MARK: - Outbound

  func subscribeList() {
    send(.subscribeList)
  }

  func subscribeSession(_ sessionId: String, sinceRevision: UInt64? = nil, includeSnapshot: Bool = true) {
    send(.subscribeSession(sessionId: sessionId, sinceRevision: sinceRevision, includeSnapshot: includeSnapshot))
  }

  func unsubscribeSession(_ sessionId: String) {
    send(.unsubscribeSession(sessionId: sessionId))
  }

  // MARK: - Testing

  func seedSessionsListForTesting(_ sessions: [ServerSessionListItem]) {
    latestSessionListItems = sessions
    hasReceivedInitialSessionsList = true
    emit(.sessionsList(sessions))
  }

  func emitForTesting(_ event: ServerEvent) {
    emit(event)
  }

  // MARK: - Private: Connection

  private func attemptConnect() {
    guard let serverURL else { return }
    guard connectAttempts < maxConnectAttempts else {
      let msg = isRemote
        ? "Could not reach remote server after \(maxConnectAttempts) attempts"
        : "Failed to connect after \(maxConnectAttempts) attempts"
      setStatus(.failed(msg))
      return
    }

    connectAttempts += 1
    setStatus(.connecting)

    stopKeepAlive()
    receiveTask?.cancel()
    receiveTask = nil
    webSocket?.cancel()
    urlSession?.invalidateAndCancel()

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 0
    urlSession = URLSession(configuration: config)

    var request = URLRequest(url: serverURL)
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }

    webSocket = urlSession?.webSocketTask(with: request)
    webSocket?.maximumMessageSize = Self.maxInboundBytes
    webSocket?.resume()
    startReceiving()

    connectTask = Task {
      do {
        try await ping()
        await MainActor.run { self.completeConnection() }
      } catch {
        guard !Task.isCancelled else { return }
        let shouldRetry = await MainActor.run { () -> Bool in
          if case .connecting = self.connectionStatus { return true }
          return false
        }
        guard shouldRetry else { return }
        let delay = min(pow(2.0, Double(connectAttempts - 1)), maxBackoffSeconds)
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        await MainActor.run { self.attemptConnect() }
      }
    }
  }

  private func completeConnection() {
    guard case .connecting = connectionStatus else { return }
    connectTask?.cancel()
    connectTask = nil
    lastConnectedAt = Date()
    setStatus(.connected)
    startKeepAlive()
    subscribeList()
  }

  private func ping() async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      webSocket?.sendPing { error in
        if let error { cont.resume(throwing: error) }
        else { cont.resume() }
      }
    }
  }

  private func startKeepAlive() {
    keepAliveTask?.cancel()
    keepAliveTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.keepAliveInterval))
        guard !Task.isCancelled else { break }
        do { try await ping() }
        catch {
          await MainActor.run { self.handleDisconnect() }
          break
        }
      }
    }
  }

  private func stopKeepAlive() {
    keepAliveTask?.cancel()
    keepAliveTask = nil
  }

  private func startReceiving() {
    receiveTask = Task { await receiveLoop() }
  }

  private func receiveLoop() async {
    while !Task.isCancelled {
      do {
        guard let message = try await webSocket?.receive() else {
          handleDisconnect()
          break
        }
        switch message {
        case let .string(text): handleFrame(text)
        case let .data(data):
          if let text = String(data: data, encoding: .utf8) { handleFrame(text) }
        @unknown default: break
        }
      } catch {
        handleDisconnect()
        break
      }
    }
  }

  private func handleDisconnect() {
    switch connectionStatus {
    case .connected, .connecting:
      if let t = lastConnectedAt, Date().timeIntervalSince(t) >= Self.stableConnectionThreshold {
        connectAttempts = 0
      }
      lastConnectedAt = nil
      attemptConnect()
    case .disconnected, .failed:
      break
    }
  }

  // MARK: - Private: Frame handling

  private func handleFrame(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }

    // If we're still connecting, receiving a frame means we're connected
    if case .connecting = connectionStatus {
      completeConnection()
    }

    // Extract revision before full decode
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let rev = json["revision"] as? Int,
       let sid = json["session_id"] as? String
    {
      emit(.revision(sessionId: sid, revision: UInt64(rev)))
    }

    do {
      let msg = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
      routeMessage(msg)
    } catch {
      // Silently ignore undecodable frames
    }
  }

  private func routeMessage(_ message: ServerToClientMessage) {
    switch message {
    case let .sessionsList(sessions): emit(.sessionsList(sessions))
    case let .conversationBootstrap(session, conversation):
      emit(.conversationBootstrap(session: session, conversation: conversation))
    case let .sessionSnapshot(session): emit(.sessionSnapshot(session))
    case let .sessionDelta(sessionId, changes): emit(.sessionDelta(sessionId: sessionId, changes: changes))
    case let .conversationRowsChanged(sessionId, upserted, removedRowIds, totalRowCount):
      emit(.conversationRowsChanged(sessionId: sessionId, upserted: upserted, removedRowIds: removedRowIds, totalRowCount: totalRowCount))
    case let .approvalRequested(sessionId, request, approvalVersion):
      emit(.approvalRequested(sessionId: sessionId, request: request, approvalVersion: approvalVersion))
    case let .approvalDecisionResult(sessionId, requestId, outcome, activeRequestId, approvalVersion):
      emit(.approvalDecisionResult(sessionId: sessionId, requestId: requestId, outcome: outcome, activeRequestId: activeRequestId, approvalVersion: approvalVersion))
    case let .tokensUpdated(sessionId, usage, snapshotKind):
      emit(.tokensUpdated(sessionId: sessionId, usage: usage, snapshotKind: snapshotKind))
    case let .sessionCreated(session): emit(.sessionCreated(session))
    case let .sessionListItemUpdated(session): emit(.sessionListItemUpdated(session))
    case let .sessionListItemRemoved(sessionId): emit(.sessionListItemRemoved(sessionId: sessionId))
    case let .sessionEnded(sessionId, reason): emit(.sessionEnded(sessionId: sessionId, reason: reason))
    case let .approvalsList(sessionId, approvals): emit(.approvalsList(sessionId: sessionId, approvals: approvals))
    case let .approvalDeleted(approvalId): emit(.approvalDeleted(approvalId: approvalId))
    case let .modelsList(models): emit(.modelsList(models))
    case let .codexAccountStatus(status): emit(.codexAccountStatus(status))
    case let .codexLoginChatgptStarted(loginId, authUrl):
      emit(.codexLoginChatgptStarted(loginId: loginId, authUrl: authUrl))
    case let .codexLoginChatgptCompleted(loginId, success, error):
      emit(.codexLoginChatgptCompleted(loginId: loginId, success: success, error: error))
    case let .codexLoginChatgptCanceled(loginId, status):
      emit(.codexLoginChatgptCanceled(loginId: loginId, status: status))
    case let .codexAccountUpdated(status): emit(.codexAccountUpdated(status))
    case let .skillsList(sessionId, skills, errors):
      emit(.skillsList(sessionId: sessionId, skills: skills, errors: errors))
    case let .remoteSkillsList(sessionId, skills):
      emit(.remoteSkillsList(sessionId: sessionId, skills: skills))
    case let .remoteSkillDownloaded(sessionId, skillId, name, path):
      emit(.remoteSkillDownloaded(sessionId: sessionId, skillId: skillId, name: name, path: path))
    case let .skillsUpdateAvailable(sessionId): emit(.skillsUpdateAvailable(sessionId: sessionId))
    case let .mcpToolsList(sessionId, tools, resources, resourceTemplates, authStatuses):
      emit(.mcpToolsList(sessionId: sessionId, tools: tools, resources: resources, resourceTemplates: resourceTemplates, authStatuses: authStatuses))
    case let .mcpStartupUpdate(sessionId, server, status):
      emit(.mcpStartupUpdate(sessionId: sessionId, server: server, status: status))
    case let .mcpStartupComplete(sessionId, ready, failed, cancelled):
      emit(.mcpStartupComplete(sessionId: sessionId, ready: ready, failed: failed, cancelled: cancelled))
    case let .claudeCapabilities(sessionId, slashCommands, skills, tools, models):
      emit(.claudeCapabilities(sessionId: sessionId, slashCommands: slashCommands, skills: skills, tools: tools, models: models))
    case let .claudeModelsList(models): emit(.claudeModelsList(models))
    case let .contextCompacted(sessionId): emit(.contextCompacted(sessionId: sessionId))
    case let .undoStarted(sessionId, message): emit(.undoStarted(sessionId: sessionId, message: message))
    case let .undoCompleted(sessionId, success, message):
      emit(.undoCompleted(sessionId: sessionId, success: success, message: message))
    case let .threadRolledBack(sessionId, numTurns):
      emit(.threadRolledBack(sessionId: sessionId, numTurns: numTurns))
    case let .sessionForked(sourceSessionId, newSessionId, forkedFromThreadId):
      emit(.sessionForked(sourceSessionId: sourceSessionId, newSessionId: newSessionId, forkedFromThreadId: forkedFromThreadId))
    case let .turnDiffSnapshot(sessionId, turnId, diff, inputTokens, outputTokens, cachedTokens, contextWindow, snapshotKind):
      emit(.turnDiffSnapshot(sessionId: sessionId, turnId: turnId, diff: diff, inputTokens: inputTokens, outputTokens: outputTokens, cachedTokens: cachedTokens, contextWindow: contextWindow, snapshotKind: snapshotKind))
    case let .reviewCommentCreated(sessionId, reviewRevision, comment):
      emit(.reviewCommentCreated(sessionId: sessionId, reviewRevision: reviewRevision, comment: comment))
    case let .reviewCommentUpdated(sessionId, reviewRevision, comment):
      emit(.reviewCommentUpdated(sessionId: sessionId, reviewRevision: reviewRevision, comment: comment))
    case let .reviewCommentDeleted(sessionId, reviewRevision, commentId):
      emit(.reviewCommentDeleted(sessionId: sessionId, reviewRevision: reviewRevision, commentId: commentId))
    case let .reviewCommentsList(sessionId, reviewRevision, comments):
      emit(.reviewCommentsList(sessionId: sessionId, reviewRevision: reviewRevision, comments: comments))
    case let .subagentToolsList(sessionId, subagentId, tools):
      emit(.subagentToolsList(sessionId: sessionId, subagentId: subagentId, tools: tools))
    case let .shellStarted(sessionId, requestId, command):
      emit(.shellStarted(sessionId: sessionId, requestId: requestId, command: command))
    case let .shellOutput(sessionId, requestId, stdout, stderr, exitCode, durationMs, outcome):
      emit(.shellOutput(sessionId: sessionId, requestId: requestId, stdout: stdout, stderr: stderr, exitCode: exitCode, durationMs: durationMs, outcome: outcome))
    case let .worktreesList(requestId, repoRoot, worktreeRevision, worktrees):
      emit(.worktreesList(requestId: requestId, repoRoot: repoRoot, worktreeRevision: worktreeRevision, worktrees: worktrees))
    case let .worktreeCreated(requestId, repoRoot, worktreeRevision, worktree):
      emit(.worktreeCreated(requestId: requestId, repoRoot: repoRoot, worktreeRevision: worktreeRevision, worktree: worktree))
    case let .worktreeRemoved(requestId, repoRoot, worktreeRevision, worktreeId):
      emit(.worktreeRemoved(requestId: requestId, repoRoot: repoRoot, worktreeRevision: worktreeRevision, worktreeId: worktreeId))
    case let .worktreeStatusChanged(worktreeId, status, repoRoot):
      emit(.worktreeStatusChanged(worktreeId: worktreeId, status: status, repoRoot: repoRoot))
    case let .worktreeError(requestId, code, message):
      emit(.worktreeError(requestId: requestId, code: code, message: message))
    case let .rateLimitEvent(sessionId, info): emit(.rateLimitEvent(sessionId: sessionId, info: info))
    case let .promptSuggestion(sessionId, suggestion):
      emit(.promptSuggestion(sessionId: sessionId, suggestion: suggestion))
    case let .filesPersisted(sessionId, files): emit(.filesPersisted(sessionId: sessionId, files: files))
    case let .serverInfo(isPrimary, claims): emit(.serverInfo(isPrimary: isPrimary, claims: claims))
    case let .permissionRules(sessionId, rules): emit(.permissionRules(sessionId: sessionId, rules: rules))
    case let .error(code, message, sessionId): emit(.error(code: code, message: message, sessionId: sessionId))
    case .directoryListing, .recentProjectsList, .openAiKeyStatus,
         .codexUsageResult, .claudeUsageResult:
      break
    }
  }

  private func emit(_ event: ServerEvent) {
    updateRootState(for: event)
    onEvent?(event)
    for listener in additionalListeners {
      listener(event)
    }
  }

  private func setStatus(_ status: ConnectionStatus) {
    guard connectionStatus != status else { return }
    connectionStatus = status
    if status != .connected {
      latestSessionListItems = []
      hasReceivedInitialSessionsList = false
    }
    emit(.connectionStatusChanged(status))
  }

  private func updateRootState(for event: ServerEvent) {
    switch event {
    case let .sessionsList(sessions):
      latestSessionListItems = sessions
      hasReceivedInitialSessionsList = true
    case let .sessionCreated(session), let .sessionListItemUpdated(session):
      if let idx = latestSessionListItems.firstIndex(where: { $0.id == session.id }) {
        latestSessionListItems[idx] = session
      } else {
        latestSessionListItems.append(session)
      }
    case let .sessionListItemRemoved(sessionId):
      latestSessionListItems.removeAll { $0.id == sessionId }
    default: break
    }
  }

  private func send(_ message: ClientToServerMessage) {
    guard let webSocket else { return }
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    guard let data = try? encoder.encode(message),
          let text = String(data: data, encoding: .utf8) else { return }
    webSocket.send(.string(text)) { _ in }
  }
}
