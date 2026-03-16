import Foundation

struct ServerConnectionListenerToken: Hashable, Sendable {
  fileprivate let rawValue: UUID

  fileprivate init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

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

  /// Messages
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
    activeRequestId: String?, approvalVersion: UInt64
  )
  case approvalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem])
  case approvalDeleted(approvalId: Int64)

  /// Tokens
  case tokensUpdated(
    sessionId: String, usage: ServerTokenUsage, snapshotKind: ServerTokenUsageSnapshotKind
  )

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

  /// MCP
  case mcpToolsList(
    sessionId: String, tools: [String: ServerMcpTool],
    resources: [String: [ServerMcpResource]],
    resourceTemplates: [String: [ServerMcpResourceTemplate]],
    authStatuses: [String: ServerMcpAuthStatus]
  )
  case mcpStartupUpdate(sessionId: String, server: String, status: ServerMcpStartupStatus)
  case mcpStartupComplete(
    sessionId: String, ready: [String], failed: [ServerMcpStartupFailure],
    cancelled: [String]
  )

  /// Claude capabilities
  case claudeCapabilities(
    sessionId: String, slashCommands: [String], skills: [String],
    tools: [String], models: [ServerClaudeModelOption]
  )

  // Context / undo / fork
  case contextCompacted(sessionId: String)
  case undoStarted(sessionId: String, message: String?)
  case undoCompleted(sessionId: String, success: Bool, message: String?)
  case threadRolledBack(sessionId: String, numTurns: UInt32)
  case sessionForked(sourceSessionId: String, newSessionId: String, forkedFromThreadId: String?)

  /// Turn diffs
  case turnDiffSnapshot(
    sessionId: String, turnId: String, diff: String,
    inputTokens: UInt64?, outputTokens: UInt64?, cachedTokens: UInt64?,
    contextWindow: UInt64?, snapshotKind: ServerTokenUsageSnapshotKind
  )

  // Review comments
  case reviewCommentCreated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentUpdated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentDeleted(sessionId: String, reviewRevision: UInt64, commentId: String)
  case reviewCommentsList(sessionId: String, reviewRevision: UInt64, comments: [ServerReviewComment])

  /// Subagent
  case subagentToolsList(sessionId: String, subagentId: String, tools: [ServerSubagentTool])

  // Shell
  case shellStarted(sessionId: String, requestId: String, command: String)
  case shellOutput(
    sessionId: String, requestId: String, stdout: String, stderr: String,
    exitCode: Int32?, durationMs: UInt64, outcome: ServerShellExecutionOutcome
  )

  // Worktrees
  case worktreesList(requestId: String, repoRoot: String?, worktreeRevision: UInt64, worktrees: [ServerWorktreeSummary])
  case worktreeCreated(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktree: ServerWorktreeSummary)
  case worktreeRemoved(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktreeId: String)
  case worktreeStatusChanged(worktreeId: String, status: ServerWorktreeStatus, repoRoot: String)
  case worktreeError(requestId: String, code: String, message: String)

  /// Rate limit
  case rateLimitEvent(sessionId: String, info: ServerRateLimitInfo)

  // Misc
  case promptSuggestion(sessionId: String, suggestion: String)
  case filesPersisted(sessionId: String, files: [String])
  case serverInfo(isPrimary: Bool, claims: [ServerClientPrimaryClaim])

  /// Error
  case error(code: String, message: String, sessionId: String?)

  /// Permission rules
  case permissionRules(sessionId: String, rules: ServerSessionPermissionRules)

  /// Connection lifecycle
  case connectionStatusChanged(ConnectionStatus)

  /// Revision tracking
  case revision(sessionId: String, revision: UInt64)
}

// MARK: - ServerConnection

/// Single connection to one OrbitDock server endpoint.
/// Owns both the WebSocket (real-time events) and HTTP execution (REST queries).
/// One connection status gates everything — when WS is down, HTTP throws immediately.
@MainActor
final class ServerConnection {
  private(set) var connectionStatus: ConnectionStatus = .disconnected
  private(set) var latestSessionListItems: [ServerSessionListItem] = []
  private(set) var hasReceivedInitialSessionsList = false

  /// Event listeners. Multiple consumers can register.
  var onEvent: ((ServerEvent) -> Void)?
  private var additionalListeners: [ServerConnectionListenerToken: (ServerEvent) -> Void] = [:]

  @discardableResult
  func addListener(_ listener: @escaping (ServerEvent) -> Void) -> ServerConnectionListenerToken {
    let token = ServerConnectionListenerToken()
    additionalListeners[token] = listener
    return token
  }

  func removeListener(_ token: ServerConnectionListenerToken) {
    additionalListeners.removeValue(forKey: token)
  }

  // MARK: - Private state

  private let authToken: String?
  private var serverURL: URL?
  private var webSocket: URLSessionWebSocketTask?
  private let wsSession: URLSession
  private let httpSession: URLSession
  private var receiveTask: Task<Void, Never>?
  private var connectTask: Task<Void, Never>?
  private var keepAliveTask: Task<Void, Never>?
  private let circuitBreaker: ConnectionCircuitBreaker
  private var stableConnectionTask: Task<Void, Never>?
  private var lastConnectedAt: Date?
  private var reconnectTask: Task<Void, Never>?
  private var connectionGeneration: UInt64 = 0

  private static let maxInboundBytes = 8 * 1_024 * 1_024
  private static let stableConnectionThreshold: TimeInterval = 30
  private static let keepAliveInterval: TimeInterval = 30

  var isRemote: Bool {
    guard let host = serverURL?.host else { return false }
    return host != "127.0.0.1" && host != "localhost" && host != "::1"
  }

  init(authToken: String?) {
    self.authToken = authToken

    // WS session: unlimited resource timeout for long-lived connection
    let wsConfig = URLSessionConfiguration.default
    wsConfig.timeoutIntervalForRequest = 10
    wsConfig.timeoutIntervalForResource = 0
    self.wsSession = URLSession(configuration: wsConfig)

    // HTTP session: bounded timeouts for data requests
    let httpConfig = URLSessionConfiguration.default
    httpConfig.timeoutIntervalForRequest = 10
    httpConfig.timeoutIntervalForResource = 60
    httpConfig.httpMaximumConnectionsPerHost = 2
    httpConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
    httpConfig.urlCache = nil
    self.httpSession = URLSession(configuration: httpConfig)

    self.circuitBreaker = .local()
    netLog(.info, cat: .ws, "ServerConnection initialized")
  }

  // MARK: - HTTP execution

  /// Execute an HTTP request. Throws `.serverUnreachable` when WS is not connected.
  func execute(_ request: URLRequest) async throws -> HTTPResponse {
    guard connectionStatus == .connected else {
      throw HTTPTransportError.serverUnreachable
    }

    let result: (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
      let task = httpSession.dataTask(with: request) { data, response, error in
        if let error {
          continuation.resume(throwing: HTTPTransportError(error: error))
        } else if let data, let response {
          continuation.resume(returning: (data, response))
        } else {
          continuation.resume(throwing: HTTPTransportError.invalidResponse)
        }
      }
      task.resume()
    }

    return try HTTPResponse(data: result.0, response: result.1)
  }

  // MARK: - WebSocket connection

  func connect(to url: URL) {
    serverURL = url
    switch connectionStatus {
      case .disconnected, .failed:
        break
      case .connecting, .connected:
        return
    }
    reconnectTask?.cancel()
    reconnectTask = nil
    attemptConnect()
  }

  func reconnectIfNeeded() {
    guard serverURL != nil else { return }
    switch connectionStatus {
      case .connected:
        guard connectTask == nil, reconnectTask == nil else { return }
        let generation = connectionGeneration
        guard let socket = webSocket else {
          handleDisconnect(expectedGeneration: generation)
          return
        }
        // Verify the connection is still alive
        Task { [weak self] in
          guard let self else { return }
          do { try await ping(on: socket) }
          catch { handleDisconnect(expectedGeneration: generation) }
        }
      case .connecting:
        break // already attempting
      case .disconnected, .failed:
        guard connectTask == nil, reconnectTask == nil else { return }
        attemptConnect()
    }
  }

  func disconnect() {
    reconnectTask?.cancel()
    reconnectTask = nil
    _ = invalidateConnectionGeneration()
    teardownConnectionTasks()
    circuitBreaker.reset()
    lastConnectedAt = nil
    latestSessionListItems = []
    hasReceivedInitialSessionsList = false
    setStatus(.disconnected)
    netLog(.info, cat: .circuit, "Circuit breaker reset (explicit disconnect)")
  }

  // MARK: - Outbound WS messages

  func subscribeList() {
    send(.subscribeList)
  }

  func subscribeSession(_ sessionId: String, sinceRevision: UInt64? = nil, includeSnapshot: Bool = true) {
    send(.subscribeSession(sessionId: sessionId, sinceRevision: sinceRevision, includeSnapshot: includeSnapshot))
  }

  func unsubscribeSession(_ sessionId: String) {
    send(.unsubscribeSession(sessionId: sessionId))
  }

  // MARK: - Sessions list (REST-driven)

  func applySessionsList(_ sessions: [ServerSessionListItem]) {
    latestSessionListItems = sessions
    hasReceivedInitialSessionsList = true
    emit(.sessionsList(sessions))
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
    switch connectionStatus {
      case .disconnected, .failed:
        break
      case .connecting, .connected:
        return
    }

    // If breaker is open, go straight to scheduled retry
    guard circuitBreaker.shouldAllow else {
      let reconnectGeneration = invalidateConnectionGeneration()
      scheduleReconnect(expectedGeneration: reconnectGeneration)
      return
    }

    reconnectTask?.cancel()
    reconnectTask = nil
    setStatus(.connecting)
    let generation = advanceConnectionGeneration()

    var request = URLRequest(url: serverURL)
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }

    let socket = wsSession.webSocketTask(with: request)
    socket.maximumMessageSize = Self.maxInboundBytes
    webSocket = socket
    socket.resume()
    startReceiving(on: socket, generation: generation)

    connectTask = Task {
      do {
        try await ping(on: socket)
        guard !Task.isCancelled, isCurrentGeneration(generation) else { return }
        completeConnection(expectedGeneration: generation)
      } catch {
        guard !Task.isCancelled else { return }
        handleDisconnect(expectedGeneration: generation)
      }
    }
  }

  private func completeConnection(expectedGeneration generation: UInt64) {
    guard isCurrentGeneration(generation) else { return }
    guard case .connecting = connectionStatus else { return }
    connectTask?.cancel()
    connectTask = nil
    lastConnectedAt = Date()
    netLog(.info, cat: .ws, "Connection complete", data: ["url": serverURL?.absoluteString ?? "nil"])
    setStatus(.connected)
    guard let socket = webSocket else { return }
    startKeepAlive(on: socket, generation: generation)
    startStableConnectionTimer(generation: generation)
    subscribeList()
  }

  private func startStableConnectionTimer(generation: UInt64) {
    stableConnectionTask?.cancel()
    stableConnectionTask = Task {
      try? await Task.sleep(for: .seconds(Self.stableConnectionThreshold))
      guard !Task.isCancelled, isCurrentGeneration(generation) else { return }
      circuitBreaker.recordSuccess()
      netLog(.info, cat: .circuit, "Circuit breaker reset (stable connection)")
    }
  }

  private func ping(on socket: URLSessionWebSocketTask) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      socket.sendPing { error in
        if let error { cont.resume(throwing: error) }
        else { cont.resume() }
      }
    }
  }

  private func startKeepAlive(on socket: URLSessionWebSocketTask, generation: UInt64) {
    keepAliveTask?.cancel()
    keepAliveTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.keepAliveInterval))
        guard !Task.isCancelled, isCurrentGeneration(generation) else { break }
        do { try await ping(on: socket) }
        catch {
          guard !Task.isCancelled else { break }
          handleDisconnect(expectedGeneration: generation)
          break
        }
      }
    }
  }

  private func stopKeepAlive() {
    keepAliveTask?.cancel()
    keepAliveTask = nil
  }

  private func startReceiving(on socket: URLSessionWebSocketTask, generation: UInt64) {
    receiveTask?.cancel()
    receiveTask = Task { await receiveLoop(on: socket, generation: generation) }
  }

  private func receiveLoop(on socket: URLSessionWebSocketTask, generation: UInt64) async {
    while !Task.isCancelled {
      guard isCurrentGeneration(generation) else { break }
      do {
        let message = try await socket.receive()
        guard !Task.isCancelled, isCurrentGeneration(generation) else { break }
        switch message {
          case let .string(text): handleFrame(text, expectedGeneration: generation)
          case let .data(data):
            if let text = String(data: data, encoding: .utf8) {
              handleFrame(text, expectedGeneration: generation)
            }
          @unknown default: break
        }
      } catch {
        guard !Task.isCancelled else { break }
        handleDisconnect(expectedGeneration: generation)
        break
      }
    }
  }

  private func handleDisconnect(expectedGeneration generation: UInt64) {
    guard isCurrentGeneration(generation) else { return }

    let reconnectGeneration = invalidateConnectionGeneration()

    teardownConnectionTasks()
    lastConnectedAt = nil

    circuitBreaker.recordFailure()
    netLog(.warning, cat: .circuit, "Circuit breaker recorded failure", data: [
      "state": String(describing: circuitBreaker.state),
      "url": serverURL?.absoluteString ?? "nil",
    ])

    setStatus(.disconnected)
    scheduleReconnect(expectedGeneration: reconnectGeneration)
  }

  private func scheduleReconnect(expectedGeneration generation: UInt64) {
    reconnectTask?.cancel()
    reconnectTask = nil

    guard serverURL != nil else { return }
    guard isCurrentGeneration(generation) else { return }

    if circuitBreaker.shouldAllow {
      // Breaker is still closed — reconnect on the next run loop tick
      // (not synchronously, so duplicate handleDisconnect calls collapse)
      reconnectTask = Task {
        await Task.yield()
        guard !Task.isCancelled, isCurrentGeneration(generation) else { return }
        reconnectTask = nil
        attemptConnect()
      }
    } else {
      let remaining = circuitBreaker.cooldownRemaining ?? 1
      let msg = isRemote
        ? "Could not reach remote server — retrying in \(Int(remaining.rounded(.up)))s"
        : "Failed to connect — retrying in \(Int(remaining.rounded(.up)))s"
      setStatus(.failed(msg))
      reconnectTask = Task {
        try? await Task.sleep(for: .seconds(max(remaining, 1)))
        guard !Task.isCancelled, isCurrentGeneration(generation) else { return }
        reconnectTask = nil
        attemptConnect()
      }
    }
  }

  // MARK: - Private: Frame handling

  private func handleFrame(_ text: String, expectedGeneration generation: UInt64) {
    guard isCurrentGeneration(generation) else { return }
    guard let data = text.data(using: .utf8) else { return }

    if case .connecting = connectionStatus {
      completeConnection(expectedGeneration: generation)
    }

    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let messageType = json?["type"] as? String
    let sessionId = json?["session_id"] as? String

    netLog(.debug, cat: .ws, "Frame received", sid: sessionId, data: [
      "type": messageType ?? "unknown",
      "bytes": text.count,
    ])

    if let json, let rev = json["revision"] as? Int, let sid = sessionId {
      emit(.revision(sessionId: sid, revision: UInt64(rev)))
    }

    do {
      let msg = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
      routeMessage(msg)
    } catch {
      let preview = String(text.prefix(500))
      netLog(.error, cat: .ws, "Failed to decode frame", sid: sessionId, data: [
        "type": messageType ?? "unknown",
        "error": String(describing: error),
        "preview": preview,
      ])
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
        emit(.conversationRowsChanged(
          sessionId: sessionId,
          upserted: upserted,
          removedRowIds: removedRowIds,
          totalRowCount: totalRowCount
        ))
      case let .approvalRequested(sessionId, request, approvalVersion):
        emit(.approvalRequested(sessionId: sessionId, request: request, approvalVersion: approvalVersion))
      case let .approvalDecisionResult(sessionId, requestId, outcome, activeRequestId, approvalVersion):
        emit(.approvalDecisionResult(
          sessionId: sessionId,
          requestId: requestId,
          outcome: outcome,
          activeRequestId: activeRequestId,
          approvalVersion: approvalVersion
        ))
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
        emit(.mcpToolsList(
          sessionId: sessionId,
          tools: tools,
          resources: resources,
          resourceTemplates: resourceTemplates,
          authStatuses: authStatuses
        ))
      case let .mcpStartupUpdate(sessionId, server, status):
        emit(.mcpStartupUpdate(sessionId: sessionId, server: server, status: status))
      case let .mcpStartupComplete(sessionId, ready, failed, cancelled):
        emit(.mcpStartupComplete(sessionId: sessionId, ready: ready, failed: failed, cancelled: cancelled))
      case let .claudeCapabilities(sessionId, slashCommands, skills, tools, models):
        emit(.claudeCapabilities(
          sessionId: sessionId,
          slashCommands: slashCommands,
          skills: skills,
          tools: tools,
          models: models
        ))
      case let .claudeModelsList(models): emit(.claudeModelsList(models))
      case let .contextCompacted(sessionId): emit(.contextCompacted(sessionId: sessionId))
      case let .undoStarted(sessionId, message): emit(.undoStarted(sessionId: sessionId, message: message))
      case let .undoCompleted(sessionId, success, message):
        emit(.undoCompleted(sessionId: sessionId, success: success, message: message))
      case let .threadRolledBack(sessionId, numTurns):
        emit(.threadRolledBack(sessionId: sessionId, numTurns: numTurns))
      case let .sessionForked(sourceSessionId, newSessionId, forkedFromThreadId):
        emit(.sessionForked(
          sourceSessionId: sourceSessionId,
          newSessionId: newSessionId,
          forkedFromThreadId: forkedFromThreadId
        ))
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
        emit(.turnDiffSnapshot(
          sessionId: sessionId,
          turnId: turnId,
          diff: diff,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cachedTokens: cachedTokens,
          contextWindow: contextWindow,
          snapshotKind: snapshotKind
        ))
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
        emit(.shellOutput(
          sessionId: sessionId,
          requestId: requestId,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          durationMs: durationMs,
          outcome: outcome
        ))
      case let .worktreesList(requestId, repoRoot, worktreeRevision, worktrees):
        emit(.worktreesList(
          requestId: requestId,
          repoRoot: repoRoot,
          worktreeRevision: worktreeRevision,
          worktrees: worktrees
        ))
      case let .worktreeCreated(requestId, repoRoot, worktreeRevision, worktree):
        emit(.worktreeCreated(
          requestId: requestId,
          repoRoot: repoRoot,
          worktreeRevision: worktreeRevision,
          worktree: worktree
        ))
      case let .worktreeRemoved(requestId, repoRoot, worktreeRevision, worktreeId):
        emit(.worktreeRemoved(
          requestId: requestId,
          repoRoot: repoRoot,
          worktreeRevision: worktreeRevision,
          worktreeId: worktreeId
        ))
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
      case .unknown:
        break // Already logged at decode time
    }
  }

  private func teardownConnectionTasks() {
    stopKeepAlive()
    stableConnectionTask?.cancel()
    stableConnectionTask = nil
    connectTask?.cancel()
    connectTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    webSocket?.cancel(with: .goingAway, reason: nil)
    webSocket = nil
  }

  private func advanceConnectionGeneration() -> UInt64 {
    connectionGeneration &+= 1
    return connectionGeneration
  }

  private func invalidateConnectionGeneration() -> UInt64 {
    advanceConnectionGeneration()
  }

  private func isCurrentGeneration(_ generation: UInt64) -> Bool {
    connectionGeneration == generation
  }

  private func emit(_ event: ServerEvent) {
    updateRootState(for: event)
    onEvent?(event)
    let listeners = Array(additionalListeners.values)
    for listener in listeners {
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
