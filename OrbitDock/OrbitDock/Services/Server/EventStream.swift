//
//  EventStream.swift
//  OrbitDock
//
//  Receive-only WebSocket that publishes server events as an AsyncStream.
//  No mutations flow through here — all actions go via APIClient HTTP.
//  Only 3 outbound messages: subscribeList, subscribeSession, unsubscribeSession.
//

import Foundation

// MARK: - Event

/// Every server push event, typed and ready for consumption by stores.
enum ServerEvent: Sendable {
  // Session list
  case sessionsList([ServerSessionSummary])
  case sessionCreated(ServerSessionSummary)
  case sessionEnded(sessionId: String, reason: String)

  // Session state
  case sessionSnapshot(ServerSessionState)
  case sessionDelta(sessionId: String, changes: ServerStateChanges)

  // Messages
  case messageAppended(sessionId: String, message: ServerMessage)
  case messageUpdated(sessionId: String, messageId: String, changes: ServerMessageChanges)

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

  // Revision tracking (for incremental replay)
  case revision(sessionId: String, revision: UInt64)
}

// MARK: - EventStream

/// Receive-only WebSocket connection that produces `ServerEvent`s via `AsyncStream`.
@MainActor
final class EventStream {
  /// Max inbound WS message size — matches server's WS_MAX_TEXT_MESSAGE_BYTES.
  private static let maxInboundBytes = 1 * 1_024 * 1_024

  private(set) var connectionStatus: ConnectionStatus = .disconnected

  /// The event stream. Consumers iterate with `for await event in eventStream.events { ... }`.
  let events: AsyncStream<ServerEvent>
  private let continuation: AsyncStream<ServerEvent>.Continuation

  private var serverURL: URL?
  private let authToken: String?
  private var webSocket: URLSessionWebSocketTask?
  private var urlSession: URLSession?
  private var receiveTask: Task<Void, Never>?
  private var connectTask: Task<Void, Never>?
  private var connectAttempts = 0

  var isRemote: Bool {
    guard let host = serverURL?.host else { return false }
    return host != "127.0.0.1" && host != "localhost" && host != "::1"
  }

  private var maxConnectAttempts: Int { isRemote ? 20 : 10 }
  private var maxBackoffSeconds: Double { isRemote ? 15.0 : 10.0 }

  init(authToken: String?) {
    self.authToken = authToken
    var cont: AsyncStream<ServerEvent>.Continuation!
    events = AsyncStream { cont = $0 }
    continuation = cont
  }

  deinit {
    continuation.finish()
  }

  // MARK: - Connection

  func connect(to url: URL) {
    switch connectionStatus {
    case .disconnected, .failed:
      connectAttempts = 0
    case .connecting, .connected:
      return
    }
    netLog(.info, cat: .ws, "Connecting", data: ["url": url.absoluteString])
    serverURL = url
    attemptConnect()
  }

  func disconnect() {
    netLog(.info, cat: .ws, "Disconnecting", data: ["url": serverURL?.absoluteString ?? "nil"])
    connectTask?.cancel()
    connectTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    webSocket?.cancel(with: .goingAway, reason: nil)
    webSocket = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    connectAttempts = 0
    setStatus(.disconnected)
  }

  // MARK: - Outbound (subscription management only)

  func subscribeList() {
    netLog(.debug, cat: .ws, "Subscribe to session list")
    send(.subscribeList)
  }

  func subscribeSession(
    _ sessionId: String, sinceRevision: UInt64? = nil, includeSnapshot: Bool = true
  ) {
    netLog(.info, cat: .ws, "Subscribe session", sid: sessionId, data: ["sinceRevision": sinceRevision.map(String.init) ?? "nil", "snapshot": includeSnapshot])
    send(.subscribeSession(
      sessionId: sessionId, sinceRevision: sinceRevision, includeSnapshot: includeSnapshot))
  }

  func unsubscribeSession(_ sessionId: String) {
    netLog(.debug, cat: .ws, "Unsubscribe session", sid: sessionId)
    send(.unsubscribeSession(sessionId: sessionId))
  }

  // MARK: - Private

  private func attemptConnect() {
    guard let serverURL else { return }
    guard connectAttempts < maxConnectAttempts else {
      netLog(.error, cat: .ws, "Connect failed: max attempts exceeded", data: ["maxAttempts": maxConnectAttempts, "url": serverURL.absoluteString])
      let msg = isRemote
        ? "Could not reach remote server after \(maxConnectAttempts) attempts"
        : "Failed to connect after \(maxConnectAttempts) attempts"
      setStatus(.failed(msg))
      return
    }

    connectAttempts += 1
    netLog(.info, cat: .ws, "Connect attempt \(connectAttempts)/\(maxConnectAttempts)", data: ["url": serverURL.absoluteString])
    setStatus(.connecting)

    receiveTask?.cancel()
    receiveTask = nil
    webSocket?.cancel()
    urlSession?.invalidateAndCancel()

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 5
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
        await MainActor.run { self.completeConnection(trigger: "ping") }
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

  private func completeConnection(trigger: String) {
    guard case .connecting = connectionStatus else { return }
    netLog(.info, cat: .ws, "Connected (trigger: \(trigger))", data: ["url": serverURL?.absoluteString ?? "?"])
    if trigger != "ping" {
      connectTask?.cancel()
      connectTask = nil
    }
    connectAttempts = 0
    setStatus(.connected)

    // Auto-subscribe to session list
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
        case let .string(text):
          handleFrame(text)
        case let .data(data):
          if let text = String(data: data, encoding: .utf8) {
            handleFrame(text)
          }
        @unknown default:
          break
        }
      } catch {
        netLog(.error, cat: .ws, "Receive error", data: ["error": error.localizedDescription])
        handleDisconnect()
        break
      }
    }
  }

  private func handleDisconnect() {
    switch connectionStatus {
    case .connected, .connecting:
      netLog(.warning, cat: .ws, "Disconnected unexpectedly, will reconnect", data: ["url": serverURL?.absoluteString ?? "?"])
      setStatus(.disconnected)
      attemptConnect()
    case .disconnected, .failed:
      break
    }
  }

  private func handleFrame(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    completeConnection(trigger: "first_frame")

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
      netLog(.warning, cat: .ws, "Undecodable frame", data: ["chars": text.count, "preview": String(text.prefix(200)), "error": error.localizedDescription])
    }
  }

  private func routeMessage(_ message: ServerToClientMessage) {
    switch message {
    case let .sessionsList(sessions):
      emit(.sessionsList(sessions))
    case let .sessionSnapshot(session):
      emit(.sessionSnapshot(session))
    case let .sessionDelta(sessionId, changes):
      emit(.sessionDelta(sessionId: sessionId, changes: changes))
    case let .messageAppended(sessionId, message):
      emit(.messageAppended(sessionId: sessionId, message: message))
    case let .messageUpdated(sessionId, messageId, changes):
      emit(.messageUpdated(sessionId: sessionId, messageId: messageId, changes: changes))
    case let .approvalRequested(sessionId, request, approvalVersion):
      emit(.approvalRequested(
        sessionId: sessionId, request: request, approvalVersion: approvalVersion))
    case let .approvalDecisionResult(sessionId, requestId, outcome, activeRequestId, approvalVersion):
      emit(.approvalDecisionResult(
        sessionId: sessionId, requestId: requestId, outcome: outcome,
        activeRequestId: activeRequestId, approvalVersion: approvalVersion))
    case let .tokensUpdated(sessionId, usage, snapshotKind):
      emit(.tokensUpdated(sessionId: sessionId, usage: usage, snapshotKind: snapshotKind))
    case let .sessionCreated(session):
      emit(.sessionCreated(session))
    case let .sessionEnded(sessionId, reason):
      emit(.sessionEnded(sessionId: sessionId, reason: reason))
    case let .approvalsList(sessionId, approvals):
      emit(.approvalsList(sessionId: sessionId, approvals: approvals))
    case let .approvalDeleted(approvalId):
      emit(.approvalDeleted(approvalId: approvalId))
    case let .modelsList(models):
      emit(.modelsList(models))
    case let .codexAccountStatus(status):
      emit(.codexAccountStatus(status))
    case let .codexLoginChatgptStarted(loginId, authUrl):
      emit(.codexLoginChatgptStarted(loginId: loginId, authUrl: authUrl))
    case let .codexLoginChatgptCompleted(loginId, success, error):
      emit(.codexLoginChatgptCompleted(loginId: loginId, success: success, error: error))
    case let .codexLoginChatgptCanceled(loginId, status):
      emit(.codexLoginChatgptCanceled(loginId: loginId, status: status))
    case let .codexAccountUpdated(status):
      emit(.codexAccountUpdated(status))
    case let .skillsList(sessionId, skills, errors):
      emit(.skillsList(sessionId: sessionId, skills: skills, errors: errors))
    case let .remoteSkillsList(sessionId, skills):
      emit(.remoteSkillsList(sessionId: sessionId, skills: skills))
    case let .remoteSkillDownloaded(sessionId, skillId, name, path):
      emit(.remoteSkillDownloaded(
        sessionId: sessionId, skillId: skillId, name: name, path: path))
    case let .skillsUpdateAvailable(sessionId):
      emit(.skillsUpdateAvailable(sessionId: sessionId))
    case let .mcpToolsList(sessionId, tools, resources, resourceTemplates, authStatuses):
      emit(.mcpToolsList(
        sessionId: sessionId, tools: tools, resources: resources,
        resourceTemplates: resourceTemplates, authStatuses: authStatuses))
    case let .mcpStartupUpdate(sessionId, server, status):
      emit(.mcpStartupUpdate(sessionId: sessionId, server: server, status: status))
    case let .mcpStartupComplete(sessionId, ready, failed, cancelled):
      emit(.mcpStartupComplete(
        sessionId: sessionId, ready: ready, failed: failed, cancelled: cancelled))
    case let .claudeCapabilities(sessionId, slashCommands, skills, tools, models):
      emit(.claudeCapabilities(
        sessionId: sessionId, slashCommands: slashCommands, skills: skills,
        tools: tools, models: models))
    case let .claudeModelsList(models):
      emit(.claudeModelsList(models))
    case let .contextCompacted(sessionId):
      emit(.contextCompacted(sessionId: sessionId))
    case let .undoStarted(sessionId, message):
      emit(.undoStarted(sessionId: sessionId, message: message))
    case let .undoCompleted(sessionId, success, message):
      emit(.undoCompleted(sessionId: sessionId, success: success, message: message))
    case let .threadRolledBack(sessionId, numTurns):
      emit(.threadRolledBack(sessionId: sessionId, numTurns: numTurns))
    case let .sessionForked(sourceSessionId, newSessionId, forkedFromThreadId):
      emit(.sessionForked(
        sourceSessionId: sourceSessionId, newSessionId: newSessionId,
        forkedFromThreadId: forkedFromThreadId))
    case let .turnDiffSnapshot(
      sessionId, turnId, diff, inputTokens, outputTokens, cachedTokens,
      contextWindow, snapshotKind):
      emit(.turnDiffSnapshot(
        sessionId: sessionId, turnId: turnId, diff: diff,
        inputTokens: inputTokens, outputTokens: outputTokens,
        cachedTokens: cachedTokens, contextWindow: contextWindow,
        snapshotKind: snapshotKind))
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
        sessionId: sessionId, requestId: requestId, stdout: stdout, stderr: stderr,
        exitCode: exitCode, durationMs: durationMs, outcome: outcome))
    case let .worktreesList(requestId, repoRoot, worktreeRevision, worktrees):
      emit(.worktreesList(
        requestId: requestId, repoRoot: repoRoot, worktreeRevision: worktreeRevision, worktrees: worktrees))
    case let .worktreeCreated(requestId, repoRoot, worktreeRevision, worktree):
      emit(.worktreeCreated(
        requestId: requestId, repoRoot: repoRoot, worktreeRevision: worktreeRevision, worktree: worktree))
    case let .worktreeRemoved(requestId, repoRoot, worktreeRevision, worktreeId):
      emit(.worktreeRemoved(
        requestId: requestId, repoRoot: repoRoot, worktreeRevision: worktreeRevision, worktreeId: worktreeId))
    case let .worktreeStatusChanged(worktreeId, status, repoRoot):
      emit(.worktreeStatusChanged(
        worktreeId: worktreeId, status: status, repoRoot: repoRoot))
    case let .worktreeError(requestId, code, message):
      emit(.worktreeError(requestId: requestId, code: code, message: message))
    case let .rateLimitEvent(sessionId, info):
      emit(.rateLimitEvent(sessionId: sessionId, info: info))
    case let .promptSuggestion(sessionId, suggestion):
      emit(.promptSuggestion(sessionId: sessionId, suggestion: suggestion))
    case let .filesPersisted(sessionId, files):
      emit(.filesPersisted(sessionId: sessionId, files: files))
    case let .serverInfo(isPrimary, claims):
      emit(.serverInfo(isPrimary: isPrimary, claims: claims))
    case let .permissionRules(sessionId, rules):
      emit(.permissionRules(sessionId: sessionId, rules: rules))
    case let .error(code, message, sessionId):
      emit(.error(code: code, message: message, sessionId: sessionId))
    // Silently ignore WS-only response types that are now fetched via HTTP
    case .directoryListing, .recentProjectsList, .openAiKeyStatus,
         .codexUsageResult, .claudeUsageResult:
      break
    }
  }

  private func emit(_ event: ServerEvent) {
    continuation.yield(event)
  }

  private func setStatus(_ status: ConnectionStatus) {
    netLog(.info, cat: .ws, "Status → \(status)")
    connectionStatus = status
    emit(.connectionStatusChanged(status))
  }

  private func send(_ message: ClientToServerMessage) {
    guard let webSocket else { return }
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    guard let data = try? encoder.encode(message),
          let text = String(data: data, encoding: .utf8)
    else { return }

    netLog(.debug, cat: .ws, "Send", data: ["preview": String(text.prefix(200))])
    webSocket.send(.string(text)) { error in
      if let error {
        netLog(.error, cat: .ws, "Send failed", data: ["error": error.localizedDescription])
      }
    }
  }
}
