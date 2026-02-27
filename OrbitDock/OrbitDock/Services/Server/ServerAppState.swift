//
//  ServerAppState.swift
//  OrbitDock
//
//  WebSocket-backed state store for server-managed sessions.
//  Listens to ServerConnection callbacks and maintains Session/TranscriptMessage
//  state that views can observe. Per-session state lives in SessionObservable;
//  this class is a registry + global state holder.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "server-app-state")

@Observable
@MainActor
final class ServerAppState {
  nonisolated static func codexModelsCacheKey(endpointId: UUID) -> String {
    "orbitdock.server.codex_models_cache.v2.\(endpointId.uuidString)"
  }

  nonisolated static func sessionsCacheKey(endpointId: UUID) -> String {
    "orbitdock.server.sessions_cache.v2.\(endpointId.uuidString)"
  }

  @ObservationIgnored
  let connection: ServerConnection

  let endpointId: UUID

  private var codexModelsCacheKey: String {
    Self.codexModelsCacheKey(endpointId: endpointId)
  }

  private var sessionsCacheKey: String {
    Self.sessionsCacheKey(endpointId: endpointId)
  }

  // MARK: - Observable State (global, not per-session)

  /// Sessions managed by the server (converted to Session model for view compatibility)
  private(set) var sessions: [Session] = [] {
    didSet {
      guard oldValue != sessions else { return }
      NotificationCenter.default.post(
        name: .serverSessionsDidChange,
        object: nil,
        userInfo: ["endpointId": endpointId]
      )
    }
  }

  private(set) var hasReceivedInitialSessionsList = false

  /// Cross-session approval history (global view)
  private(set) var globalApprovalHistory: [ServerApprovalHistoryItem] = []

  /// Codex models discovered by the server for the current account
  private(set) var codexModels: [ServerCodexModelOption] = []

  /// Claude models discovered from Claude CLI initialize response
  private(set) var claudeModels: [ServerClaudeModelOption] = []

  /// Current Codex account/auth status (global account state, not per-session)
  private(set) var codexAccountStatus: ServerCodexAccountStatus?

  /// Most recent Codex auth/login error suitable for UI display
  private(set) var codexAuthError: String?

  /// Most recent unhandled server error — surfaced as a toast/alert so errors are never silent
  private(set) var lastServerError: (code: String, message: String)?

  // MARK: - Per-Session Observable Registry

  @ObservationIgnored
  private var _sessionObservables: [String: SessionObservable] = [:]

  /// Get or create per-session observable. Does NOT trigger observation on ServerAppState.
  func session(_ id: String) -> SessionObservable {
    if let existing = _sessionObservables[id] { return existing }
    let obs = SessionObservable(id: id)
    _sessionObservables[id] = obs
    return obs
  }

  /// Copy all Session struct fields to the per-session observable so detail views
  /// can read from the observable instead of the struct.
  func hydrateObservable(_ obs: SessionObservable, from sess: Session) {
    obs.endpointId = sess.endpointId
    obs.endpointName = sess.endpointName
    obs.projectPath = sess.projectPath
    obs.projectName = sess.projectName
    obs.branch = sess.branch
    obs.model = sess.model
    obs.effort = sess.effort
    obs.summary = sess.summary
    obs.customName = sess.customName
    obs.firstPrompt = sess.firstPrompt
    obs.lastMessage = sess.lastMessage
    obs.transcriptPath = sess.transcriptPath
    obs.status = sess.status
    obs.workStatus = sess.workStatus
    obs.attentionReason = sess.attentionReason
    obs.lastActivityAt = sess.lastActivityAt
    obs.lastTool = sess.lastTool
    obs.lastToolAt = sess.lastToolAt
    obs.inputTokens = sess.inputTokens
    obs.outputTokens = sess.outputTokens
    obs.cachedTokens = sess.cachedTokens
    obs.contextWindow = sess.contextWindow
    obs.totalTokens = sess.totalTokens
    obs.totalCostUSD = sess.totalCostUSD
    obs.provider = sess.provider
    obs.codexIntegrationMode = sess.codexIntegrationMode
    obs.claudeIntegrationMode = sess.claudeIntegrationMode
    obs.codexThreadId = sess.codexThreadId
    obs.pendingApprovalId = sess.pendingApprovalId
    obs.pendingToolName = sess.pendingToolName
    obs.pendingToolInput = sess.pendingToolInput
    obs.pendingPermissionDetail = sess.pendingPermissionDetail
    obs.pendingQuestion = sess.pendingQuestion
    obs.promptCount = sess.promptCount
    obs.toolCount = sess.toolCount
    obs.startedAt = sess.startedAt
    obs.endedAt = sess.endedAt
    obs.endReason = sess.endReason
    obs.tokenUsageSnapshotKind = sess.tokenUsageSnapshotKind
    obs.gitSha = sess.gitSha
    obs.currentCwd = sess.currentCwd
    obs.repositoryRoot = sess.repositoryRoot
    obs.isWorktree = sess.isWorktree
    obs.worktreeId = sess.worktreeId
  }

  // MARK: - Private Internal State

  /// Last known server revision per session (for incremental reconnection)
  private var lastRevision: [String: UInt64] = [:]

  /// Raw config values used to derive autonomy accurately across partial deltas
  private var approvalPolicies: [String: String] = [:]
  private var sandboxModes: [String: String] = [:]
  private var permissionModes: [String: String] = [:]

  /// Track which sessions we're subscribed to
  private var subscribedSessions: Set<String> = []

  /// Temporary: autonomy level from the most recent createSession call
  private var pendingCreationAutonomy: AutonomyLevel?

  /// When true, navigate to the next session that gets created
  private var pendingNavigationOnCreate = false

  private struct ApprovalDispatchKey: Hashable {
    let sessionId: String
    let requestId: String
  }

  /// Client-side idempotency for approval/question decisions.
  private var inFlightApprovalDispatches: Set<ApprovalDispatchKey> = []

  /// Request details received for queued approvals that are not yet the active queue head.
  /// Keyed by `sessionId` then normalized `requestId`.
  private var queuedApprovalRequests: [String: [String: ServerApprovalRequest]] = [:]

  private struct SessionsCachePayload: Codable {
    let cachedAt: Date
    let summaries: [ServerSessionSummary]
  }

  enum ApprovalDispatchResult: Equatable {
    case dispatched
    case stale(nextPendingRequestId: String?)
  }

  init(connection: ServerConnection, endpointId: UUID) {
    self.connection = connection
    self.endpointId = endpointId

    if AppRuntimeMode.current == .mock {
      sessions = Self.mockSessions()
      hasReceivedInitialSessionsList = true
      return
    }

    if let cached = loadSessionsCache() {
      sessions = cached.summaries.map { $0.toSession() }
      logger.info("Loaded cached sessions list: \(cached.summaries.count) sessions")
    }

    if let data = UserDefaults.standard.data(forKey: codexModelsCacheKey),
       let models = try? JSONDecoder().decode([ServerCodexModelOption].self, from: data)
    {
      codexModels = models
    }
  }

  convenience init() {
    let endpoint = ServerEndpointSettings.defaultEndpoint
    let connection = ServerConnection(endpoint: endpoint)
    self.init(connection: connection, endpointId: endpoint.id)
  }

  var codexAccount: ServerCodexAccount? {
    codexAccountStatus?.account
  }

  var codexAuthMode: ServerCodexAuthMode? {
    codexAccountStatus?.authMode
  }

  var codexRequiresOpenAIAuth: Bool {
    codexAccountStatus?.requiresOpenaiAuth ?? true
  }

  var codexLoginInProgress: Bool {
    codexAccountStatus?.loginInProgress ?? false
  }

  var codexActiveLoginId: String? {
    codexAccountStatus?.activeLoginId
  }

  var isLoadingInitialSessions: Bool {
    !hasReceivedInitialSessionsList && sessions.isEmpty
  }

  var isRefreshingCachedSessions: Bool {
    !hasReceivedInitialSessionsList && !sessions.isEmpty
  }

  // MARK: - Setup

  /// Wire up ServerConnection callbacks. Call after connection is established.
  func setup() {
    let conn = connection

    conn.onSessionsList = { [weak self] summaries in
      Task { @MainActor in
        self?.handleSessionsList(summaries)
      }
    }

    conn.onSessionSnapshot = { [weak self] state in
      Task { @MainActor in
        self?.handleSessionSnapshot(state)
      }
    }

    conn.onSessionDelta = { [weak self] sessionId, changes in
      Task { @MainActor in
        self?.handleSessionDelta(sessionId, changes)
      }
    }

    conn.onMessageAppended = { [weak self] sessionId, message in
      Task { @MainActor in
        self?.handleMessageAppended(sessionId, message)
      }
    }

    conn.onMessageUpdated = { [weak self] sessionId, messageId, changes in
      Task { @MainActor in
        self?.handleMessageUpdated(sessionId, messageId, changes)
      }
    }

    conn.onApprovalRequested = { [weak self] sessionId, request, approvalVersion in
      Task { @MainActor in
        self?.handleApprovalRequested(sessionId, request, approvalVersion: approvalVersion)
      }
    }

    conn.onApprovalDecisionResult = { [weak self] sessionId, requestId, outcome, activeRequestId, approvalVersion in
      Task { @MainActor in
        self?.handleApprovalDecisionResult(
          sessionId: sessionId,
          requestId: requestId,
          outcome: outcome,
          activeRequestId: activeRequestId,
          approvalVersion: approvalVersion
        )
      }
    }

    conn.onTokensUpdated = { [weak self] sessionId, usage, snapshotKind in
      Task { @MainActor in
        self?.handleTokensUpdated(sessionId, usage, snapshotKind: snapshotKind)
      }
    }

    conn.onSessionCreated = { [weak self] summary in
      Task { @MainActor in
        self?.handleSessionCreated(summary)
      }
    }

    conn.onSessionEnded = { [weak self] sessionId, reason in
      Task { @MainActor in
        self?.handleSessionEnded(sessionId, reason)
      }
    }

    conn.onApprovalsList = { [weak self] sessionId, approvals in
      Task { @MainActor in
        self?.handleApprovalsList(sessionId: sessionId, approvals: approvals)
      }
    }

    conn.onApprovalDeleted = { [weak self] approvalId in
      Task { @MainActor in
        self?.handleApprovalDeleted(approvalId: approvalId)
      }
    }

    conn.onModelsList = { [weak self] models in
      Task { @MainActor in
        self?.codexModels = models
        self?.persistCodexModelsCache(models)
      }
    }

    conn.onCodexAccountStatus = { [weak self] status in
      Task { @MainActor in
        self?.applyCodexAccountStatus(status)
      }
    }

    conn.onCodexLoginChatgptStarted = { [weak self] loginId, authUrl in
      Task { @MainActor in
        guard let self else { return }
        self.codexAuthError = nil
        self.markLoginInProgress(loginId: loginId)
        self.openCodexAuthURL(authUrl)
      }
    }

    conn.onCodexLoginChatgptCompleted = { [weak self] loginId, success, error in
      Task { @MainActor in
        guard let self else { return }
        if let activeLoginId = self.codexActiveLoginId, activeLoginId != loginId {
          logger.debug("Ignoring stale login completion for \(loginId)")
          return
        }
        self.markLoginInProgress(loginId: nil)
        if success {
          self.codexAuthError = nil
        } else {
          self.codexAuthError = error ?? "ChatGPT sign-in failed"
        }
        self.refreshCodexAccount()
      }
    }

    conn.onCodexLoginChatgptCanceled = { [weak self] loginId, status in
      Task { @MainActor in
        guard let self else { return }
        if let activeLoginId = self.codexActiveLoginId, activeLoginId != loginId {
          logger.debug("Ignoring stale login cancel for \(loginId)")
          return
        }
        self.markLoginInProgress(loginId: nil)
        switch status {
          case .canceled:
            self.codexAuthError = nil
          case .notFound:
            self.codexAuthError = "No active ChatGPT login was found to cancel."
          case .invalidId:
            self.codexAuthError = "Invalid login session. Please try signing in again."
        }
        self.refreshCodexAccount()
      }
    }

    conn.onCodexAccountUpdated = { [weak self] status in
      Task { @MainActor in
        self?.applyCodexAccountStatus(status)
      }
    }

    conn.onClaudeCapabilities = { [weak self] sessionId, slashCommands, skills, tools, models in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        if !slashCommands.isEmpty {
          obs.slashCommands = Set(slashCommands)
        }
        if !skills.isEmpty {
          obs.claudeSkillNames = skills
        }
        if !tools.isEmpty {
          obs.claudeToolNames = tools
        }
        if !models.isEmpty {
          self.claudeModels = models
        }
      }
    }

    conn.onClaudeModelsList = { [weak self] models in
      Task { @MainActor in
        if !models.isEmpty {
          self?.claudeModels = models
        }
      }
    }

    conn.onSkillsList = { [weak self] sessionId, entries, _ in
      Task { @MainActor in
        let allSkills = entries.flatMap(\.skills)
        self?.session(sessionId).skills = allSkills
      }
    }

    conn.onSkillsUpdateAvailable = { [weak self] sessionId in
      Task { @MainActor in
        self?.connection.listSkills(sessionId: sessionId)
      }
    }

    conn.onMcpToolsList = { [weak self] sessionId, tools, resources, _, authStatuses in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        obs.mcpTools = tools
        obs.mcpResources = resources
        obs.mcpAuthStatuses = authStatuses
        logger.info("MCP tools list received for \(sessionId): \(tools.count) tools")
      }
    }

    conn.onMcpStartupUpdate = { [weak self] sessionId, server, status in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        var state = obs.mcpStartupState ?? McpStartupState()
        state.serverStatuses[server] = status
        obs.mcpStartupState = state
        logger.info("MCP startup update for \(sessionId): \(server)")
      }
    }

    conn.onMcpStartupComplete = { [weak self] sessionId, ready, failed, cancelled in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        var state = obs.mcpStartupState ?? McpStartupState()
        state.readyServers = ready
        state.failedServers = failed
        state.cancelledServers = cancelled
        state.isComplete = true
        obs.mcpStartupState = state
        logger.info("MCP startup complete for \(sessionId): \(ready.count) ready, \(failed.count) failed")
        if self.shouldRequestCodexConnectorData(sessionId: sessionId) {
          self.connection.listMcpTools(sessionId: sessionId)
        }
      }
    }

    conn
      .onTurnDiffSnapshot =
      { [weak self] sessionId, turnId, diff, inputTokens, outputTokens, cachedTokens, contextWindow, snapshotKind in
        Task { @MainActor in
          self?.handleTurnDiffSnapshot(
            sessionId,
            turnId: turnId,
            diff: diff,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedTokens: cachedTokens,
            contextWindow: contextWindow,
            snapshotKind: snapshotKind
          )
        }
      }

    conn.onReviewCommentCreated = { [weak self] sessionId, comment in
      Task { @MainActor in
        self?.handleReviewCommentCreated(sessionId, comment: comment)
      }
    }

    conn.onReviewCommentUpdated = { [weak self] sessionId, comment in
      Task { @MainActor in
        self?.handleReviewCommentUpdated(sessionId, comment: comment)
      }
    }

    conn.onReviewCommentDeleted = { [weak self] sessionId, commentId in
      Task { @MainActor in
        self?.handleReviewCommentDeleted(sessionId, commentId: commentId)
      }
    }

    conn.onReviewCommentsList = { [weak self] sessionId, comments in
      Task { @MainActor in
        self?.session(sessionId).reviewComments = comments
      }
    }

    conn.onSubagentToolsList = { [weak self] sessionId, subagentId, tools in
      Task { @MainActor in
        self?.session(sessionId).subagentTools[subagentId] = tools
      }
    }

    conn.onShellOutput = { [weak self] sessionId, requestId, stdout, stderr, exitCode, durationMs, outcome in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        let output = stderr.isEmpty ? stdout : (stdout.isEmpty ? stderr : "\(stdout)\n\(stderr)")
        let isError = self.shellOutputIsError(outcome: outcome, exitCode: exitCode)
        // Find the shell message to get the command
        let command = obs.messages.first(where: { $0.id == requestId })?.content ?? ""
        obs.bufferShellContext(command: command, output: output, exitCode: exitCode)

        // Update the in-progress shell message with output
        if let idx = obs.messages.firstIndex(where: { $0.id == requestId }) {
          obs.messages[idx].toolOutput = output
          obs.messages[idx].toolDuration = Double(durationMs) / 1_000.0
          obs.messages[idx].isError = isError
          obs.messages[idx].isInProgress = false
          obs.bumpMessagesRevision()
        }
      }
    }

    conn.onContextCompacted = { [weak self] sessionId in
      Task { @MainActor in
        self?.handleContextCompacted(sessionId)
      }
    }

    conn.onUndoStarted = { [weak self] sessionId, _ in
      Task { @MainActor in
        self?.session(sessionId).undoInProgress = true
      }
    }

    conn.onUndoCompleted = { [weak self] sessionId, _, _ in
      Task { @MainActor in
        self?.session(sessionId).undoInProgress = false
      }
    }

    conn.onRevision = { [weak self] sessionId, revision in
      Task { @MainActor in
        self?.lastRevision[sessionId] = revision
      }
    }

    conn.onSessionForked = { [weak self] sourceSessionId, newSessionId, _ in
      Task { @MainActor in
        guard let self else { return }
        self.session(sourceSessionId).forkInProgress = false
        self.session(newSessionId).forkedFrom = sourceSessionId
        logger.info("Fork tracked: \(newSessionId) forked from \(sourceSessionId)")
        NotificationCenter.default.post(
          name: .selectSession,
          object: nil,
          userInfo: ["sessionId": SessionRef(endpointId: self.endpointId, sessionId: newSessionId).scopedID]
        )
      }
    }

    conn.onError = { [weak self] code, message, sessionId in
      Task { @MainActor in
        self?.handleError(code, message, sessionId)
      }
    }

    conn.onDisconnected = { [weak self] in
      Task { @MainActor in
        self?.hasReceivedInitialSessionsList = false
      }
    }

    conn.onConnected = { [weak self] in
      Task { @MainActor in
        self?.resubscribeAll()
        self?.refreshCodexModels()
        self?.refreshCodexAccount()
        self?.refreshClaudeModels()
      }
    }

    logger.info("ServerAppState callbacks wired")
    refreshCodexModels()
    refreshCodexAccount()
    refreshClaudeModels()
  }

  // MARK: - Actions

  /// Create a new Codex session
  func createSession(cwd: String, model: String? = nil, approvalPolicy: String? = nil, sandboxMode: String? = nil) {
    logger.info("Creating Codex session in \(cwd)")
    let autonomy = AutonomyLevel.from(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode)
    pendingCreationAutonomy = autonomy
    pendingNavigationOnCreate = true
    connection.createSession(
      provider: .codex,
      cwd: cwd,
      model: model,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode
    )
  }

  /// Create a new Claude direct session
  func createClaudeSession(
    cwd: String,
    model: String? = nil,
    permissionMode: String? = nil,
    allowedTools: [String] = [],
    disallowedTools: [String] = [],
    effort: String? = nil
  ) {
    logger.info("Creating Claude session in \(cwd)")
    pendingNavigationOnCreate = true
    connection.createSession(
      provider: .claude,
      cwd: cwd,
      model: model,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: permissionMode,
      allowedTools: allowedTools,
      disallowedTools: disallowedTools,
      effort: effort
    )
  }

  /// Refresh model options from the server.
  func refreshCodexModels() {
    connection.listModels()
  }

  /// Refresh cached Claude models from the server DB.
  /// Models are populated when Claude sessions are created.
  func refreshClaudeModels() {
    connection.listClaudeModels()
  }

  /// Refresh global Codex account/auth status.
  func refreshCodexAccount(refreshToken: Bool = false) {
    connection.readCodexAccount(refreshToken: refreshToken)
  }

  /// Start ChatGPT browser login for Codex.
  func startCodexChatgptLogin() {
    codexAuthError = nil
    connection.startCodexChatgptLogin()
  }

  /// Cancel an in-progress ChatGPT browser login for Codex.
  func cancelCodexChatgptLogin() {
    guard let loginId = codexActiveLoginId else {
      codexAuthError = "No active sign-in request to cancel."
      return
    }
    connection.cancelCodexChatgptLogin(loginId: loginId)
  }

  /// Log out the current Codex account.
  func logoutCodexAccount() {
    connection.logoutCodexAccount()
  }

  /// Refresh the server-authoritative sessions list.
  func refreshSessionsList() {
    connection.subscribeList()
  }

  private func persistCodexModelsCache(_ models: [ServerCodexModelOption]) {
    if let data = try? JSONEncoder().encode(models) {
      UserDefaults.standard.set(data, forKey: codexModelsCacheKey)
    }
  }

  private func loadSessionsCache() -> SessionsCachePayload? {
    guard let data = UserDefaults.standard.data(forKey: sessionsCacheKey) else {
      return nil
    }

    guard let cached = try? JSONDecoder().decode(SessionsCachePayload.self, from: data) else {
      UserDefaults.standard.removeObject(forKey: sessionsCacheKey)
      return nil
    }

    return cached
  }

  private func persistSessionsCache(_ summaries: [ServerSessionSummary]) {
    let payload = SessionsCachePayload(cachedAt: Date(), summaries: summaries)
    if let data = try? JSONEncoder().encode(payload) {
      UserDefaults.standard.set(data, forKey: sessionsCacheKey)
    }
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
    logger.info("Sending message to \(sessionId)")
    connection.sendMessage(
      sessionId: sessionId,
      content: content,
      model: model,
      effort: effort,
      skills: skills,
      images: images,
      mentions: mentions
    )
  }

  /// Request the list of available skills for a session
  func listSkills(sessionId: String) {
    guard shouldRequestCodexConnectorData(sessionId: sessionId) else { return }
    connection.listSkills(sessionId: sessionId)
  }

  /// Resolve the next pending approval request ID for a session.
  /// Single source: reads from the observable's pending approval (server-authoritative).
  func nextPendingApprovalRequestId(sessionId: String) -> String? {
    if let requestId = normalizedApprovalRequestId(session(sessionId).pendingApproval?.id) {
      return requestId
    }
    // Fallback to list model for sessions not yet subscribed
    if let requestId = normalizedApprovalRequestId(
      sessions.first(where: { $0.id == sessionId })?.pendingApprovalId
    ) {
      return requestId
    }
    return nil
  }

  /// Resolve approval type for a specific pending request.
  func pendingApprovalType(sessionId: String, requestId: String? = nil) -> ServerApprovalType? {
    let targetRequestId = requestId ?? nextPendingApprovalRequestId(sessionId: sessionId)
    guard let targetRequestId else { return nil }

    if let approval = session(sessionId).pendingApproval, approval.id == targetRequestId {
      return approval.type
    }
    return nil
  }

  /// Approve or reject a tool with a specific decision
  @discardableResult
  func approveTool(
    sessionId: String,
    requestId: String,
    decision: String,
    message: String? = nil,
    interrupt: Bool? = nil
  ) -> ApprovalDispatchResult {
    guard let normalizedRequestId = normalizedApprovalRequestId(requestId) else {
      logger.warning("Ignoring empty tool approval request in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    guard hasActivePendingApproval(sessionId: sessionId, requestId: normalizedRequestId) else {
      logger.warning("Ignoring stale tool approval for \(requestId) in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    guard !isApprovalDispatchInFlight(sessionId: sessionId, requestId: normalizedRequestId) else {
      logger.info("Ignoring duplicate tool approval for \(normalizedRequestId) in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    markApprovalDispatchInFlight(sessionId: sessionId, requestId: normalizedRequestId)
    logger.info("Approving tool \(normalizedRequestId) in \(sessionId): \(decision)")

    connection.approveTool(
      sessionId: sessionId,
      requestId: normalizedRequestId,
      decision: decision,
      message: message,
      interrupt: interrupt
    )
    return .dispatched
  }

  /// Answer a question
  @discardableResult
  func answerQuestion(
    sessionId: String,
    requestId: String,
    answer: String,
    questionId: String? = nil,
    answers: [String: [String]]? = nil
  ) -> ApprovalDispatchResult {
    guard let normalizedRequestId = normalizedApprovalRequestId(requestId) else {
      logger.warning("Ignoring empty question approval request in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    guard hasActivePendingApproval(sessionId: sessionId, requestId: normalizedRequestId) else {
      logger.warning("Ignoring stale question answer for \(requestId) in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    guard !isApprovalDispatchInFlight(sessionId: sessionId, requestId: normalizedRequestId) else {
      logger.info("Ignoring duplicate question answer for \(normalizedRequestId) in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    markApprovalDispatchInFlight(sessionId: sessionId, requestId: normalizedRequestId)
    logger.info("Answering question \(normalizedRequestId) in \(sessionId)")
    connection.answerQuestion(
      sessionId: sessionId,
      requestId: normalizedRequestId,
      answer: answer,
      questionId: questionId,
      answers: answers
    )
    return .dispatched
  }

  /// Steer the active turn with additional guidance
  func steerTurn(
    sessionId: String,
    content: String,
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) {
    logger.info("Steering turn for \(sessionId)")
    connection.steerTurn(
      sessionId: sessionId,
      content: content,
      images: images,
      mentions: mentions
    )
  }

  /// Compact (summarize) the conversation context
  func compactContext(sessionId: String) {
    logger.info("Compacting context for \(sessionId)")
    connection.compactContext(sessionId: sessionId)
  }

  /// Undo the last turn (reverts filesystem changes + removes from context)
  func undoLastTurn(sessionId: String) {
    logger.info("Undoing last turn for \(sessionId)")
    connection.undoLastTurn(sessionId: sessionId)
  }

  /// Roll back N turns from context (does NOT revert filesystem changes)
  func rollbackTurns(sessionId: String, numTurns: UInt32) {
    logger.info("Rolling back \(numTurns) turns for \(sessionId)")
    connection.rollbackTurns(sessionId: sessionId, numTurns: numTurns)
  }

  /// Fork a session (creates a new session with conversation history)
  func forkSession(sessionId: String, nthUserMessage: UInt32? = nil) {
    logger.info("Forking session \(sessionId) at turn \(nthUserMessage.map(String.init) ?? "full")")
    session(sessionId).forkInProgress = true
    connection.forkSession(sourceSessionId: sessionId, nthUserMessage: nthUserMessage)
  }

  /// Execute a shell command in a session's working directory (does not trigger AI response)
  func executeShell(sessionId: String, command: String, cwd: String? = nil) {
    logger.info("Executing shell in \(sessionId): \(command)")
    connection.executeShell(sessionId: sessionId, command: command, cwd: cwd)
  }

  /// Cancel an in-flight shell command by request ID
  func cancelShell(sessionId: String, requestId: String) {
    logger.info("Canceling shell command in \(sessionId): \(requestId)")
    connection.cancelShell(sessionId: sessionId, requestId: requestId)
  }

  /// Interrupt a session
  func interruptSession(_ sessionId: String) {
    logger.info("Interrupting session \(sessionId)")
    connection.interruptSession(sessionId)
  }

  /// End a session
  func endSession(_ sessionId: String) {
    logger.info("Ending session \(sessionId)")
    connection.endSession(sessionId)
  }

  /// Resume an ended session
  func resumeSession(_ sessionId: String) {
    logger.info("Resuming session \(sessionId)")
    connLog(.info, category: .resume, "ServerAppState.resumeSession", sessionId: sessionId)
    subscribedSessions.insert(sessionId)
    connection.resumeSession(sessionId)
  }

  /// Take over a passive session (flip to direct mode so we can send messages)
  func takeoverSession(_ sessionId: String) {
    logger.info("Taking over session \(sessionId)")
    subscribedSessions.insert(sessionId)

    // Optimistic: set Direct immediately for instant UI feedback
    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      switch sessions[idx].provider {
        case .codex:
          sessions[idx].codexIntegrationMode = .direct
        case .claude:
          sessions[idx].claudeIntegrationMode = .direct
      }
    }

    connection.takeoverSession(sessionId: sessionId)
  }

  /// Rename a session
  func renameSession(sessionId: String, name: String?) {
    logger.info("Renaming session \(sessionId) to '\(name ?? "(cleared)")'")
    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].customName = name
    }
    connection.renameSession(sessionId: sessionId, name: name)
  }

  /// Update session config (change autonomy level mid-session)
  func updateSessionConfig(sessionId: String, autonomy: AutonomyLevel) {
    logger.info("Updating session config \(sessionId) to \(autonomy.displayName)")
    session(sessionId).autonomy = autonomy
    connection.updateSessionConfig(
      sessionId: sessionId,
      approvalPolicy: autonomy.approvalPolicy,
      sandboxMode: autonomy.sandboxMode
    )
  }

  /// Update permission mode for a Claude direct session
  func updateClaudePermissionMode(sessionId: String, mode: ClaudePermissionMode) {
    logger.info("Updating Claude permission mode \(sessionId) to \(mode.displayName)")
    session(sessionId).permissionMode = mode
    permissionModes[sessionId] = mode.rawValue
    connection.updateSessionConfig(
      sessionId: sessionId,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: mode.rawValue
    )
  }

  /// Subscribe to a session's updates (called when viewing a session)
  func subscribeToSession(_ sessionId: String) {
    guard !subscribedSessions.contains(sessionId) else { return }
    subscribedSessions.insert(sessionId)

    Task { @MainActor in
      var sinceRev = lastRevision[sessionId]
      var includeSnapshot = true

      do {
        let snapshot = try await connection.fetchSessionSnapshot(sessionId)
        guard subscribedSessions.contains(sessionId) else { return }
        handleSessionSnapshot(snapshot)
        if let revision = snapshot.revision {
          sinceRev = revision
          includeSnapshot = false
        }
      } catch {
        logger.warning("HTTP snapshot bootstrap failed for \(sessionId): \(error.localizedDescription)")
      }

      guard subscribedSessions.contains(sessionId) else { return }

      connection.subscribeSession(
        sessionId,
        sinceRevision: sinceRev,
        includeSnapshot: includeSnapshot
      )
      connection.listApprovals(sessionId: sessionId, limit: 200)
      logger.debug(
        "Subscribed to session \(sessionId) (sinceRevision: \(sinceRev.map(String.init) ?? "nil"), includeSnapshot: \(includeSnapshot))"
      )
    }
  }

  /// Unsubscribe from a session (called when navigating away)
  func unsubscribeFromSession(_ sessionId: String) {
    subscribedSessions.remove(sessionId)
    connection.unsubscribeSession(sessionId)
    trimInactiveSessionPayload(sessionId, reason: "unsubscribe")
    logger.debug("Unsubscribed from session \(sessionId)")
  }

  /// Called by app lifecycle when memory pressure is signaled.
  /// Trims heavy payloads for sessions that are not currently subscribed.
  func handleMemoryPressure() {
    let inactiveSessionIds = _sessionObservables.keys.filter { !subscribedSessions.contains($0) }
    for sessionId in inactiveSessionIds {
      trimInactiveSessionPayload(sessionId, reason: "memory-pressure")
    }
  }

  /// Check if a session ID belongs to a server-managed session
  func isServerSession(_ sessionId: String) -> Bool {
    sessions.contains { $0.id == sessionId }
  }

  /// Load approval history for one session
  func loadApprovalHistory(sessionId: String, limit: Int = 200) {
    connection.listApprovals(sessionId: sessionId, limit: limit)
  }

  /// Load global approval history across all sessions
  func loadGlobalApprovalHistory(limit: Int = 200) {
    connection.listApprovals(sessionId: nil, limit: limit)
  }

  /// Delete one approval history item
  func deleteApproval(approvalId: Int64) {
    connection.deleteApproval(approvalId)
  }

  /// Request subagent tools from the server
  func getSubagentTools(sessionId: String, subagentId: String) {
    connection.getSubagentTools(sessionId: sessionId, subagentId: subagentId)
  }

  /// List MCP tools for a session
  func listMcpTools(sessionId: String) {
    guard shouldRequestCodexConnectorData(sessionId: sessionId) else { return }
    connection.listMcpTools(sessionId: sessionId)
  }

  /// Refresh MCP servers for a session
  func refreshMcpServers(sessionId: String) {
    connection.refreshMcpServers(sessionId: sessionId)
  }

  // MARK: - Reconnection

  /// Re-subscribe to all previously subscribed sessions after reconnect
  private func resubscribeAll() {
    let sessions = subscribedSessions
    subscribedSessions.removeAll()
    logger.info("Re-subscribing to \(sessions.count) session(s) after reconnect")
    for sessionId in sessions {
      subscribeToSession(sessionId)
    }
  }

  // MARK: - Message Handlers

  private func handleSessionsList(_ summaries: [ServerSessionSummary]) {
    logger.info("Received sessions list: \(summaries.count) sessions")
    hasReceivedInitialSessionsList = true
    persistSessionsCache(summaries)

    // Merge: preserve local state for sessions we're actively subscribed to,
    // since the subscription channel (snapshots + deltas) is authoritative.
    let currentById = Dictionary(
      sessions.map { ($0.id, $0) },
      uniquingKeysWith: { _, new in new }
    )
    sessions = summaries.map { summary in
      if subscribedSessions.contains(summary.id),
         let existing = currentById[summary.id]
      {
        return existing
      }
      return summary.toSession()
    }

    // Hydrate observables for non-subscribed sessions (subscribed ones get
    // hydrated via snapshot/delta, so skip them to avoid overwriting richer state)
    for sess in sessions where !subscribedSessions.contains(sess.id) {
      hydrateObservable(session(sess.id), from: sess)
    }

    for summary in summaries {
      if summary.provider == .codex {
        setConfigCache(sessionId: summary.id, approvalPolicy: summary.approvalPolicy, sandboxMode: summary.sandboxMode)
        session(summary.id).autonomy = AutonomyLevel.from(
          approvalPolicy: summary.approvalPolicy,
          sandboxMode: summary.sandboxMode
        )
      } else if summary.provider == .claude {
        if let pm = summary.permissionMode {
          permissionModes[summary.id] = pm
        } else {
          permissionModes.removeValue(forKey: summary.id)
        }
        session(summary.id).permissionMode =
          ClaudePermissionMode(rawValue: permissionModes[summary.id] ?? "default") ?? .default
      }
    }

    // Clean up observables for sessions that disappeared from the server
    let liveIds = Set(summaries.map(\.id))
    let staleIds = _sessionObservables.keys.filter { !liveIds.contains($0) }
    for id in staleIds {
      _sessionObservables.removeValue(forKey: id)
    }
  }

  private func handleApprovalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem]) {
    if let sessionId {
      session(sessionId).approvalHistory = approvals
    } else {
      globalApprovalHistory = approvals
    }
  }

  private func handleApprovalDeleted(approvalId: Int64) {
    globalApprovalHistory.removeAll { $0.id == approvalId }
    for (id, obs) in _sessionObservables {
      if obs.approvalHistory.contains(where: { $0.id == approvalId }) {
        _sessionObservables[id]?.approvalHistory.removeAll { $0.id == approvalId }
      }
    }
  }

  private func handleSessionSnapshot(_ state: ServerSessionState) {
    logger.info("Received snapshot for \(state.id): \(state.messages.count) messages")

    // Track revision for incremental reconnection
    if let rev = state.revision {
      lastRevision[state.id] = rev
    }

    // Mark as subscribed (server pre-subscribes creator on CreateSession)
    subscribedSessions.insert(state.id)

    // Update session in list
    var sess = state.toSession()
    sess.customName = state.customName
    updateSessionInList(sess)

    // Hydrate observable with session-level fields
    let obs = session(state.id)
    hydrateObservable(obs, from: sess)
    let snapshotMessages = state.messages.map { $0.toTranscriptMessage() }
    obs.messages = normalizedTranscriptMessages(snapshotMessages, sessionId: state.id, source: "snapshot")
    obs.hasReceivedSnapshot = true
    obs.bumpMessagesRevision()

    if let approval = state.pendingApproval {
      obs.pendingApproval = approval
      if let normalized = normalizedApprovalRequestId(approval.id) {
        queuedApprovalRequests[state.id]?.removeValue(forKey: normalized)
      }
    } else {
      obs.pendingApproval = nil
      if state.pendingApprovalId == nil {
        queuedApprovalRequests[state.id] = nil
      }
    }
    if let version = state.approvalVersion {
      obs.approvalVersion = version
    }
    reconcileApprovalDispatchState(
      sessionId: state.id,
      activeRequestId: state.pendingApproval?.id ?? state.pendingApprovalId
    )

    obs.tokenUsage = state.tokenUsage
    obs.tokenUsageSnapshotKind = state.tokenUsageSnapshotKind

    if state.provider == .codex || state.claudeIntegrationMode == .direct {
      setConfigCache(sessionId: state.id, approvalPolicy: state.approvalPolicy, sandboxMode: state.sandboxMode)
      obs.autonomy = AutonomyLevel.from(
        approvalPolicy: state.approvalPolicy,
        sandboxMode: state.sandboxMode
      )
    }

    // Hydrate permission mode from snapshot for Claude direct sessions.
    if state.provider == .claude, state.claudeIntegrationMode == .direct {
      if let pm = state.permissionMode {
        permissionModes[state.id] = pm
      }
      obs.permissionMode = ClaudePermissionMode(rawValue: permissionModes[state.id] ?? "default") ?? .default
    }

    if let diff = state.currentDiff {
      obs.diff = diff
    }
    if let plan = state.currentPlan {
      obs.plan = plan
    }

    if let sourceId = state.forkedFromSessionId {
      obs.forkedFrom = sourceId
    }

    // Turn tracking
    obs.currentTurnId = state.currentTurnId
    obs.turnCount = state.turnCount
    obs.turnDiffs = normalizedTurnDiffs(state.turnDiffs, sessionId: state.id, source: "snapshot")

    // Subagents
    obs.subagents = state.subagents

    // Navigate to newly created session on snapshot (arrives before SessionCreated,
    // so the view gets the full state including integration mode immediately).
    if pendingNavigationOnCreate {
      pendingNavigationOnCreate = false
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": SessionRef(endpointId: endpointId, sessionId: state.id).scopedID]
      )
    }
  }

  private func handleSessionDelta(_ sessionId: String, _ changes: ServerStateChanges) {
    logger.debug("Session delta for \(sessionId)")

    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    var sess = sessions[idx]
    let obs = session(sessionId)
    let hadPendingApproval = obs.pendingApproval != nil

    if let status = changes.status {
      let mapped: Session.SessionStatus = status == .active ? .active : .ended
      sess.status = mapped
      obs.status = mapped
    }
    if let workStatus = changes.workStatus {
      let mapped = workStatus.toSessionWorkStatus()
      let attention = workStatus.toAttentionReason()
      sess.workStatus = mapped
      sess.attentionReason = attention
      obs.workStatus = mapped
      obs.attentionReason = attention
    }
    if let approvalOuter = changes.pendingApproval {
      let incomingVersion = changes.approvalVersion ?? 0
      let isStale = incomingVersion > 0 && incomingVersion < obs.approvalVersion

      if isStale {
        logger
          .debug(
            "[approval] ignored stale delta v\(incomingVersion) (current: \(obs.approvalVersion)) for \(sessionId)"
          )
      } else {
        if incomingVersion > 0 {
          obs.approvalVersion = incomingVersion
        }

        if let approval = approvalOuter {
          obs.pendingApproval = approval
          if let normalized = normalizedApprovalRequestId(approval.id) {
            queuedApprovalRequests[sessionId]?.removeValue(forKey: normalized)
          }
          let toolName = approval.toolNameForDisplay
          let toolInput = approval.toolInputForDisplay
          let permDetail = approval.preview?.compact
            ?? String.shellCommandDisplay(from: approval.command)
            ?? approval.command
          let question = approval.questionPrompts.first?.question ?? approval.question
          let attention: Session.AttentionReason = approval.type == .question ? .awaitingQuestion : .awaitingPermission

          sess.pendingApprovalId = approval.id
          sess.pendingToolName = toolName
          sess.pendingToolInput = toolInput
          sess.pendingPermissionDetail = permDetail
          sess.pendingQuestion = question
          sess.attentionReason = attention
          sess.workStatus = .permission

          obs.pendingApprovalId = approval.id
          obs.pendingToolName = toolName
          obs.pendingToolInput = toolInput
          obs.pendingPermissionDetail = permDetail
          obs.pendingQuestion = question
          obs.attentionReason = attention
          obs.workStatus = .permission
        } else {
          obs.pendingApproval = nil
          queuedApprovalRequests[sessionId] = nil
          sess.pendingApprovalId = nil
          sess.pendingToolName = nil
          sess.pendingToolInput = nil
          sess.pendingPermissionDetail = nil
          sess.pendingQuestion = nil

          obs.pendingApprovalId = nil
          obs.pendingToolName = nil
          obs.pendingToolInput = nil
          obs.pendingPermissionDetail = nil
          obs.pendingQuestion = nil
        }
      }
    }
    if let usage = changes.tokenUsage {
      obs.tokenUsage = usage
      let total = Int(usage.inputTokens + usage.outputTokens)
      let input = Int(usage.inputTokens)
      let output = Int(usage.outputTokens)
      let cached = Int(usage.cachedTokens)
      let window = Int(usage.contextWindow)
      sess.totalTokens = total
      sess.inputTokens = input
      sess.outputTokens = output
      sess.cachedTokens = cached
      sess.contextWindow = window
      obs.totalTokens = total
      obs.inputTokens = input
      obs.outputTokens = output
      obs.cachedTokens = cached
      obs.contextWindow = window
    }
    if let snapshotKind = changes.tokenUsageSnapshotKind {
      obs.tokenUsageSnapshotKind = snapshotKind
      sess.tokenUsageSnapshotKind = snapshotKind
    }
    if let diffOuter = changes.currentDiff {
      if let diff = diffOuter {
        obs.diff = diff
        sess.currentDiff = diff
      } else {
        obs.diff = nil
        sess.currentDiff = nil
      }
    }
    if let planOuter = changes.currentPlan {
      if let plan = planOuter {
        obs.plan = plan
      } else {
        obs.plan = nil
      }
    }
    if let nameOuter = changes.customName {
      let val = nameOuter
      sess.customName = val
      obs.customName = val
    }
    if let summaryOuter = changes.summary {
      let val = summaryOuter
      sess.summary = val
      obs.summary = val
    }
    if let firstPromptOuter = changes.firstPrompt {
      let val = firstPromptOuter
      sess.firstPrompt = val
      obs.firstPrompt = val
    }
    if let lastMessageOuter = changes.lastMessage {
      let val = lastMessageOuter
      sess.lastMessage = val
      obs.lastMessage = val
    }
    if let modeOuter = changes.codexIntegrationMode {
      let val = modeOuter.flatMap { $0.toSessionMode() }
      sess.codexIntegrationMode = val
      obs.codexIntegrationMode = val
    }
    if let modeOuter = changes.claudeIntegrationMode {
      let val = modeOuter.flatMap { $0.toSessionMode() }
      sess.claudeIntegrationMode = val
      obs.claudeIntegrationMode = val
    }
    if let approvalOuter = changes.approvalPolicy {
      setConfigCache(
        sessionId: sessionId,
        approvalPolicy: approvalOuter,
        sandboxMode: sandboxModes[sessionId]
      )
    }
    if let sandboxOuter = changes.sandboxMode {
      setConfigCache(
        sessionId: sessionId,
        approvalPolicy: approvalPolicies[sessionId],
        sandboxMode: sandboxOuter
      )
    }
    if changes.approvalPolicy != nil || changes.sandboxMode != nil {
      let approval = approvalPolicies[sessionId]
      let sandbox = sandboxModes[sessionId]
      obs.autonomy = AutonomyLevel.from(approvalPolicy: approval, sandboxMode: sandbox)
    }
    if let turnIdOuter = changes.currentTurnId {
      if let turnId = turnIdOuter {
        obs.currentTurnId = turnId
      } else {
        obs.currentTurnId = nil
      }
    }
    if let count = changes.turnCount {
      obs.turnCount = count
    }
    if let branchOuter = changes.gitBranch {
      sess.branch = branchOuter
      obs.branch = branchOuter
    }
    if let shaOuter = changes.gitSha {
      sess.gitSha = shaOuter
      obs.gitSha = shaOuter
    }
    if let cwdOuter = changes.currentCwd {
      sess.currentCwd = cwdOuter
      obs.currentCwd = cwdOuter
    }
    if let modelOuter = changes.model {
      sess.model = modelOuter
      obs.model = modelOuter
    }
    if let effortOuter = changes.effort {
      sess.effort = effortOuter
      obs.effort = effortOuter
    }
    if let pmOuter = changes.permissionMode {
      if let pm = pmOuter {
        permissionModes[sessionId] = pm
      } else {
        permissionModes.removeValue(forKey: sessionId)
      }
      obs.permissionMode = ClaudePermissionMode(rawValue: permissionModes[sessionId] ?? "default") ?? .default
    }
    if let lastActivity = changes.lastActivityAt {
      let stripped = lastActivity.hasSuffix("Z") ? String(lastActivity.dropLast()) : lastActivity
      if let secs = TimeInterval(stripped) {
        let date = Date(timeIntervalSince1970: secs)
        sess.lastActivityAt = date
        obs.lastActivityAt = date
      }
    }
    if let repoRootOuter = changes.repositoryRoot {
      sess.repositoryRoot = repoRootOuter
      obs.repositoryRoot = repoRootOuter
    }
    if let isWt = changes.isWorktree {
      sess.isWorktree = isWt
      obs.isWorktree = isWt
    }

    sessions[idx] = sess
    reconcileApprovalDispatchState(
      sessionId: sessionId,
      activeRequestId: sess.pendingApprovalId ?? obs.pendingApproval?.id
    )

    // Keep approval history in sync when approval resolves without a manual UI action
    let hasPendingApproval = obs.pendingApproval != nil
    if hadPendingApproval, !hasPendingApproval {
      refreshApprovalHistory(sessionId: sessionId)
    }
  }

  private func refreshApprovalHistory(sessionId: String) {
    connection.listApprovals(sessionId: sessionId, limit: 200)
    connection.listApprovals(sessionId: nil, limit: 200)
  }

  private func hasActivePendingApproval(sessionId: String, requestId: String) -> Bool {
    guard let normalizedRequestId = normalizedApprovalRequestId(requestId) else { return false }
    return nextPendingApprovalRequestId(sessionId: sessionId) == normalizedRequestId
  }

  private func mergeMessage(_ existing: TranscriptMessage, with incoming: TranscriptMessage) -> TranscriptMessage {
    let mergedThinking: String? = {
      if let incomingThinking = incoming.thinking,
         !incomingThinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return incomingThinking
      }
      return existing.thinking
    }()

    return TranscriptMessage(
      id: incoming.id,
      type: incoming.type,
      content: incoming.content.isEmpty ? existing.content : incoming.content,
      timestamp: incoming.timestamp,
      toolName: incoming.toolName ?? existing.toolName,
      toolInput: incoming.toolInput ?? existing.toolInput,
      toolOutput: incoming.toolOutput ?? existing.toolOutput,
      toolDuration: incoming.toolDuration ?? existing.toolDuration,
      inputTokens: incoming.inputTokens ?? existing.inputTokens,
      outputTokens: incoming.outputTokens ?? existing.outputTokens,
      isError: incoming.isError || existing.isError,
      isInProgress: incoming.isInProgress,
      images: incoming.images.isEmpty ? existing.images : incoming.images,
      thinking: mergedThinking
    )
  }

  private func withMessageID(_ message: TranscriptMessage, id: String) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      type: message.type,
      content: message.content,
      timestamp: message.timestamp,
      toolName: message.toolName,
      toolInput: message.toolInput,
      toolOutput: message.toolOutput,
      toolDuration: message.toolDuration,
      inputTokens: message.inputTokens,
      outputTokens: message.outputTokens,
      isError: message.isError,
      isInProgress: message.isInProgress,
      images: message.images,
      thinking: message.thinking
    )
  }

  private func syntheticMessageID(
    sessionId: String,
    source: String,
    index: Int,
    message: TranscriptMessage
  ) -> String {
    let millis = Int(message.timestamp.timeIntervalSince1970 * 1_000)
    let tool = message.toolName ?? "-"
    return "synthetic:\(sessionId):\(source):\(message.type.rawValue):\(millis):\(index):\(tool):\(message.content.count)"
  }

  private func normalizedTranscriptMessages(
    _ incoming: [TranscriptMessage],
    sessionId: String,
    source: String
  ) -> [TranscriptMessage] {
    guard !incoming.isEmpty else { return [] }

    var normalized: [TranscriptMessage] = []
    normalized.reserveCapacity(incoming.count)
    var indexByID: [String: Int] = [:]
    var syntheticCount = 0
    var duplicateCount = 0

    for (index, raw) in incoming.enumerated() {
      let trimmedID = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
      let messageID: String
      if trimmedID.isEmpty {
        messageID = syntheticMessageID(sessionId: sessionId, source: source, index: index, message: raw)
        syntheticCount += 1
      } else {
        messageID = trimmedID
      }

      let message = messageID == raw.id ? raw : withMessageID(raw, id: messageID)

      if let existingIndex = indexByID[messageID] {
        normalized[existingIndex] = mergeMessage(normalized[existingIndex], with: message)
        duplicateCount += 1
      } else {
        indexByID[messageID] = normalized.count
        normalized.append(message)
      }
    }

    if syntheticCount > 0 || duplicateCount > 0 {
      logger.warning(
        "Normalized messages for \(sessionId, privacy: .public) source=\(source, privacy: .public) in=\(incoming.count, privacy: .public) out=\(normalized.count, privacy: .public) synthetic=\(syntheticCount, privacy: .public) duplicates=\(duplicateCount, privacy: .public)"
      )
    }

    return normalized
  }

  private func normalizedTurnDiffs(
    _ incoming: [ServerTurnDiff],
    sessionId: String,
    source: String
  ) -> [ServerTurnDiff] {
    guard !incoming.isEmpty else { return [] }

    var byTurnId: [String: ServerTurnDiff] = [:]
    var orderedTurnIds: [String] = []
    byTurnId.reserveCapacity(incoming.count)
    orderedTurnIds.reserveCapacity(incoming.count)
    var duplicateCount = 0

    for turnDiff in incoming {
      if byTurnId[turnDiff.turnId] == nil {
        orderedTurnIds.append(turnDiff.turnId)
      } else {
        duplicateCount += 1
      }
      byTurnId[turnDiff.turnId] = turnDiff
    }

    let normalized = orderedTurnIds.compactMap { byTurnId[$0] }
    if duplicateCount > 0 {
      logger.warning(
        "Normalized turn diffs for \(sessionId, privacy: .public) source=\(source, privacy: .public) in=\(incoming.count, privacy: .public) out=\(normalized.count, privacy: .public) duplicates=\(duplicateCount, privacy: .public)"
      )
    }
    return normalized
  }

  private func handleMessageAppended(_ sessionId: String, _ message: ServerMessage) {
    logger.debug("Message event for \(sessionId): id=\(message.id, privacy: .public) type=\(message.type.rawValue)")
    guard let transcriptMsg = normalizedTranscriptMessages(
      [message.toTranscriptMessage()],
      sessionId: sessionId,
      source: "append"
    ).first
    else { return }

    let obs = session(sessionId)
    var messages = obs.messages
    let beforeCount = messages.count

    let mergeAction: String
    if let idx = messages.firstIndex(where: { $0.id == transcriptMsg.id }) {
      messages[idx] = mergeMessage(messages[idx], with: transcriptMsg)
      mergeAction = "merged"
    } else {
      messages.append(transcriptMsg)
      mergeAction = "appended"
    }

    obs.messages = normalizedTranscriptMessages(messages, sessionId: sessionId, source: "append-state")
    obs.bumpMessagesRevision()
    logger.debug(
      "Message \(mergeAction, privacy: .public) for \(sessionId): id=\(transcriptMsg.id, privacy: .public) before=\(beforeCount, privacy: .public) after=\(obs.messages.count, privacy: .public)"
    )
  }

  private func handleMessageUpdated(_ sessionId: String, _ messageId: String, _ changes: ServerMessageChanges) {
    logger.debug("Message updated in \(sessionId): \(messageId)")

    let obs = session(sessionId)
    var messages = obs.messages

    guard let idx = messages.firstIndex(where: { $0.id == messageId }) else {
      guard let content = changes.content else { return }
      let fallback = TranscriptMessage(
        id: messageId,
        type: .assistant,
        content: content,
        timestamp: Date(),
        toolName: nil,
        toolInput: nil,
        toolOutput: changes.toolOutput,
        toolDuration: changes.durationMs.map { Double($0) / 1_000.0 },
        inputTokens: nil,
        outputTokens: nil,
        isError: changes.isError ?? false,
        isInProgress: changes.isInProgress ?? false
      )
      messages.append(fallback)
      obs.messages = normalizedTranscriptMessages(messages, sessionId: sessionId, source: "update-fallback")
      obs.bumpMessagesRevision()
      logger.warning("Message update arrived before create; upserted \(messageId) in \(sessionId)")
      return
    }

    var msg = messages[idx]
    if let content = changes.content {
      msg = TranscriptMessage(
        id: msg.id,
        type: msg.type,
        content: content,
        timestamp: msg.timestamp,
        toolName: msg.toolName,
        toolInput: msg.toolInput,
        toolOutput: changes.toolOutput ?? msg.toolOutput,
        toolDuration: changes.durationMs.map { Double($0) / 1_000.0 } ?? msg.toolDuration,
        inputTokens: msg.inputTokens,
        outputTokens: msg.outputTokens,
        isError: changes.isError ?? msg.isError,
        isInProgress: changes.isInProgress ?? msg.isInProgress,
        images: msg.images,
        thinking: msg.thinking
      )
    } else {
      if let output = changes.toolOutput {
        msg.toolOutput = output
      }
      if let durationMs = changes.durationMs {
        msg.toolDuration = Double(durationMs) / 1_000.0
      }
      if let isError = changes.isError {
        msg.isError = isError
      }
      if let isInProgress = changes.isInProgress {
        msg.isInProgress = isInProgress
      }
    }
    messages[idx] = msg
    obs.messages = normalizedTranscriptMessages(messages, sessionId: sessionId, source: "update")
    obs.bumpMessagesRevision()
  }

  private func handleApprovalRequested(
    _ sessionId: String,
    _ request: ServerApprovalRequest,
    approvalVersion: UInt64?
  ) {
    let obs = session(sessionId)
    guard let normalizedRequestId = normalizedApprovalRequestId(request.id) else {
      logger.warning("[approval] ignoring request with empty request id for session \(sessionId)")
      return
    }
    let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId })
    let sessionPendingId = sessionIndex.flatMap { index in
      normalizedApprovalRequestId(sessions[index].pendingApprovalId)
    }
    let currentActiveRequestId = normalizedApprovalRequestId(obs.pendingApproval?.id) ?? sessionPendingId

    // Version gating: discard events older than what we already have
    if let version = approvalVersion, version <= obs.approvalVersion {
      logger.debug("[approval] ignored stale event v\(version) (current: \(obs.approvalVersion)) for \(sessionId)")
      return
    }

    logger
      .info(
        "[approval] received: session=\(sessionId) request=\(request.id) version=\(approvalVersion.map(String.init) ?? "nil") type=\(request.type.rawValue)"
      )

    if let version = approvalVersion {
      obs.approvalVersion = version
    }

    if let currentActiveRequestId, currentActiveRequestId != normalizedRequestId {
      logger.info(
        "[approval] queued request observed: session=\(sessionId) active=\(currentActiveRequestId) queued=\(normalizedRequestId)"
      )
      var queued = queuedApprovalRequests[sessionId] ?? [:]
      queued[normalizedRequestId] = request
      queuedApprovalRequests[sessionId] = queued
      reconcileApprovalDispatchState(
        sessionId: sessionId,
        activeRequestId: currentActiveRequestId
      )
      return
    }

    queuedApprovalRequests[sessionId]?.removeValue(forKey: normalizedRequestId)

    obs.pendingApproval = request

    let toolName = request.toolNameForDisplay
    let toolInput = request.toolInputForDisplay
    let permDetail = request.preview?.compact
      ?? String.shellCommandDisplay(from: request.command)
      ?? request.command
    let question = request.questionPrompts.first?.question ?? request.question
    let attention: Session.AttentionReason = request.type == .question ? .awaitingQuestion : .awaitingPermission

    obs.pendingApprovalId = normalizedRequestId
    obs.pendingToolName = toolName
    obs.pendingToolInput = toolInput
    obs.pendingPermissionDetail = permDetail
    obs.pendingQuestion = question
    obs.attentionReason = attention
    obs.workStatus = .permission

    if let idx = sessionIndex {
      var sess = sessions[idx]
      sess.pendingApprovalId = normalizedRequestId
      sess.pendingToolName = toolName
      sess.pendingToolInput = toolInput
      sess.pendingPermissionDetail = permDetail
      sess.pendingQuestion = question
      sess.attentionReason = attention
      sess.workStatus = .permission
      sessions[idx] = sess
    }

    reconcileApprovalDispatchState(
      sessionId: sessionId,
      activeRequestId: normalizedApprovalRequestId(request.id)
    )
  }

  private func handleApprovalDecisionResult(
    sessionId: String,
    requestId: String,
    outcome: String,
    activeRequestId: String?,
    approvalVersion: UInt64
  ) {
    logger
      .info(
        "[approval] result: session=\(sessionId) request=\(requestId) outcome=\(outcome) version=\(approvalVersion)"
      )

    let obs = session(sessionId)
    obs.approvalVersion = approvalVersion

    // Clear in-flight tracking for the decided request
    clearApprovalDispatchForRequest(sessionId: sessionId, requestId: requestId)

    let normalizedDecided = normalizedApprovalRequestId(requestId)
    if let normalizedDecided {
      queuedApprovalRequests[sessionId]?.removeValue(forKey: normalizedDecided)
    }

    let normalizedActiveRequestId = normalizedApprovalRequestId(activeRequestId)

    // Eagerly clear the pending approval if it matches the decided request so the
    // approval card disappears immediately rather than lingering until the next
    // session state delta arrives.
    if let pending = obs.pendingApproval, normalizedApprovalRequestId(pending.id) == normalizedDecided {
      obs.pendingApproval = nil
      obs.pendingApprovalId = nil
      obs.pendingToolName = nil
      obs.pendingToolInput = nil
      obs.pendingPermissionDetail = nil
      obs.pendingQuestion = nil
      if obs.attentionReason == .awaitingPermission || obs.attentionReason == .awaitingQuestion {
        obs.attentionReason = .none
      }
      if obs.workStatus == .permission {
        obs.workStatus = .working
      }

      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        var sess = sessions[idx]
        sess.pendingApprovalId = nil
        sess.pendingToolName = nil
        sess.pendingToolInput = nil
        sess.pendingPermissionDetail = nil
        sess.pendingQuestion = nil
        if sess.attentionReason == .awaitingPermission || sess.attentionReason == .awaitingQuestion {
          sess.attentionReason = .none
        }
        if sess.workStatus == .permission {
          sess.workStatus = .working
        }
        sessions[idx] = sess
      }
    }

    if
      let normalizedActiveRequestId,
      normalizedApprovalRequestId(obs.pendingApproval?.id) != normalizedActiveRequestId,
      let promoted = queuedApprovalRequests[sessionId]?[normalizedActiveRequestId]
    {
      logger.info(
        "[approval] promoted queued request after decision: session=\(sessionId) request=\(normalizedActiveRequestId)"
      )
      queuedApprovalRequests[sessionId]?.removeValue(forKey: normalizedActiveRequestId)
      obs.pendingApproval = promoted

      let toolName = promoted.toolNameForDisplay
      let toolInput = promoted.toolInputForDisplay
      let permDetail = promoted.preview?.compact
        ?? String.shellCommandDisplay(from: promoted.command)
        ?? promoted.command
      let question = promoted.questionPrompts.first?.question ?? promoted.question
      let attention: Session.AttentionReason = promoted.type == .question ? .awaitingQuestion : .awaitingPermission

      obs.pendingApprovalId = normalizedActiveRequestId
      obs.pendingToolName = toolName
      obs.pendingToolInput = toolInput
      obs.pendingPermissionDetail = permDetail
      obs.pendingQuestion = question
      obs.attentionReason = attention
      obs.workStatus = .permission

      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        var sess = sessions[idx]
        sess.pendingApprovalId = normalizedActiveRequestId
        sess.pendingToolName = toolName
        sess.pendingToolInput = toolInput
        sess.pendingPermissionDetail = permDetail
        sess.pendingQuestion = question
        sess.attentionReason = attention
        sess.workStatus = .permission
        sessions[idx] = sess
      }
    } else if normalizedActiveRequestId == nil, obs.pendingApproval == nil {
      queuedApprovalRequests[sessionId] = nil
    }

    reconcileApprovalDispatchState(
      sessionId: sessionId,
      activeRequestId: normalizedActiveRequestId
    )

    // Refresh approval history for the history panel
    refreshApprovalHistory(sessionId: sessionId)
  }

  private func clearApprovalDispatchForRequest(sessionId: String, requestId: String) {
    let key = ApprovalDispatchKey(sessionId: sessionId, requestId: requestId)
    inFlightApprovalDispatches.remove(key)
  }

  private func shellOutputIsError(outcome: ServerShellExecutionOutcome, exitCode: Int32?) -> Bool {
    switch outcome {
      case .completed:
        exitCode != 0
      case .failed, .timedOut:
        true
      case .canceled:
        false
    }
  }

  private func handleTokensUpdated(
    _ sessionId: String,
    _ usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) {
    let obs = session(sessionId)
    obs.tokenUsage = usage
    obs.tokenUsageSnapshotKind = snapshotKind
    obs.totalTokens = Int(usage.inputTokens + usage.outputTokens)
    obs.inputTokens = Int(usage.inputTokens)
    obs.outputTokens = Int(usage.outputTokens)
    obs.cachedTokens = Int(usage.cachedTokens)
    obs.contextWindow = Int(usage.contextWindow)

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].totalTokens = Int(usage.inputTokens + usage.outputTokens)
      sessions[idx].inputTokens = Int(usage.inputTokens)
      sessions[idx].outputTokens = Int(usage.outputTokens)
      sessions[idx].cachedTokens = Int(usage.cachedTokens)
      sessions[idx].contextWindow = Int(usage.contextWindow)
      sessions[idx].tokenUsageSnapshotKind = snapshotKind
    }
  }

  private func handleContextCompacted(_ sessionId: String) {
    logger.info("Context compacted for \(sessionId)")

    let obs = session(sessionId)
    let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId })
    let sessionOutput = sessionIndex.flatMap { sessions[$0].outputTokens } ?? 0
    let sessionWindow = sessionIndex.flatMap { sessions[$0].contextWindow } ?? 0
    let outputTokens = obs.tokenUsage?.outputTokens ?? UInt64(max(sessionOutput, 0))
    let contextWindow = obs.tokenUsage?.contextWindow ?? UInt64(max(sessionWindow, 0))

    let resetUsage = ServerTokenUsage(
      inputTokens: 0,
      outputTokens: outputTokens,
      cachedTokens: 0,
      contextWindow: contextWindow
    )
    obs.tokenUsage = resetUsage
    obs.tokenUsageSnapshotKind = .compactionReset
    obs.totalTokens = Int(outputTokens)
    obs.inputTokens = 0
    obs.outputTokens = Int(outputTokens)
    obs.cachedTokens = 0
    obs.contextWindow = Int(contextWindow)

    if let idx = sessionIndex {
      sessions[idx].totalTokens = Int(outputTokens)
      sessions[idx].inputTokens = 0
      sessions[idx].outputTokens = Int(outputTokens)
      sessions[idx].cachedTokens = 0
      sessions[idx].contextWindow = Int(contextWindow)
      sessions[idx].tokenUsageSnapshotKind = .compactionReset
    }
  }

  private func handleSessionCreated(_ summary: ServerSessionSummary) {
    logger.info("Session created: \(summary.id)")
    let sess = summary.toSession()

    if let idx = sessions.firstIndex(where: { $0.id == sess.id }) {
      sessions[idx] = sess
    } else {
      sessions.append(sess)
    }

    hydrateObservable(session(summary.id), from: sess)

    if let autonomy = pendingCreationAutonomy {
      session(summary.id).autonomy = autonomy
      pendingCreationAutonomy = nil
    } else if summary.provider == .codex {
      setConfigCache(sessionId: summary.id, approvalPolicy: summary.approvalPolicy, sandboxMode: summary.sandboxMode)
      session(summary.id).autonomy = AutonomyLevel.from(
        approvalPolicy: summary.approvalPolicy,
        sandboxMode: summary.sandboxMode
      )
    } else if summary.provider == .claude, let pm = summary.permissionMode {
      permissionModes[summary.id] = pm
      session(summary.id).permissionMode = ClaudePermissionMode(rawValue: pm) ?? .default
    }

    subscribeToSession(summary.id)

    // Navigation now handled in handleSessionSnapshot (arrives earlier with full state).
    // Fall back here only if snapshot was missed (e.g. reconnect race).
    if pendingNavigationOnCreate {
      pendingNavigationOnCreate = false
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": SessionRef(endpointId: endpointId, sessionId: summary.id).scopedID]
      )
    }
  }

  private func handleSessionEnded(_ sessionId: String, _ reason: String) {
    logger.info("Session ended: \(sessionId) (\(reason))")

    let obs = session(sessionId)
    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].status = .ended
      sessions[idx].workStatus = .unknown
      sessions[idx].attentionReason = .none
    }
    obs.status = .ended
    obs.workStatus = .unknown
    obs.endReason = reason

    // Clear transient per-session state (keeps messages/tokens/history for viewing)
    obs.clearTransientState()

    // Clean up internal tracking
    subscribedSessions.remove(sessionId)
    lastRevision.removeValue(forKey: sessionId)
    approvalPolicies.removeValue(forKey: sessionId)
    sandboxModes.removeValue(forKey: sessionId)
    permissionModes.removeValue(forKey: sessionId)
    queuedApprovalRequests.removeValue(forKey: sessionId)
    clearApprovalDispatchState(sessionId: sessionId)
    // Keep SessionObservable alive — user may still be viewing the conversation
  }

  private func handleError(_ code: String, _ message: String, _ sessionId: String?) {
    logger.error("Server error [\(code)]: \(message)")

    var handled = false

    if code == "fork_failed" || code == "not_found" {
      if let sid = sessionId {
        session(sid).forkInProgress = false
      }
      handled = true
    }

    // Broadcast subscriber lagged — re-subscribe to get a fresh snapshot
    if code == "lagged", let sid = sessionId {
      logger.info("Re-subscribing to \(sid) after lagged broadcast")
      subscribedSessions.remove(sid)
      subscribeToSession(sid)
      handled = true
    }

    if code == "stale_approval_request", let sid = sessionId {
      clearApprovalDispatchState(sessionId: sid)
      refreshApprovalHistory(sessionId: sid)
      handled = true
    }

    if code.hasPrefix("codex_auth_") {
      codexAuthError = message
      // Only re-fetch account status for real auth errors from the server.
      // Connection failures use "codex_auth_connection" — retrying those
      // creates an infinite loop (fetch fails → error → fetch → …).
      if code == "codex_auth_error" {
        refreshCodexAccount()
      }
      handled = true
    }

    // Surface unhandled errors so they're never silent
    if !handled {
      lastServerError = (code: code, message: message)
    }
  }

  /// Clear the last server error (call after displaying it)
  func clearServerError() {
    lastServerError = nil
  }

  private func normalizedApprovalRequestId(_ requestId: String?) -> String? {
    guard let requestId else { return nil }
    let normalized = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private func isApprovalDispatchInFlight(sessionId: String, requestId: String) -> Bool {
    inFlightApprovalDispatches.contains(ApprovalDispatchKey(sessionId: sessionId, requestId: requestId))
  }

  private func markApprovalDispatchInFlight(sessionId: String, requestId: String) {
    inFlightApprovalDispatches.insert(ApprovalDispatchKey(sessionId: sessionId, requestId: requestId))
  }

  private func clearApprovalDispatchState(sessionId: String) {
    inFlightApprovalDispatches = inFlightApprovalDispatches.filter { $0.sessionId != sessionId }
  }

  private func reconcileApprovalDispatchState(sessionId: String, activeRequestId: String?) {
    let normalizedActiveRequestId = normalizedApprovalRequestId(activeRequestId)
    inFlightApprovalDispatches = inFlightApprovalDispatches.filter { key in
      guard key.sessionId == sessionId else { return true }
      guard let normalizedActiveRequestId else { return false }
      return key.requestId == normalizedActiveRequestId
    }
  }

  // MARK: - Turn Diff Handlers

  private func handleTurnDiffSnapshot(
    _ sessionId: String,
    turnId: String,
    diff: String,
    inputTokens: UInt64?,
    outputTokens: UInt64?,
    cachedTokens: UInt64?,
    contextWindow: UInt64?,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) {
    logger.debug("Turn diff snapshot for \(sessionId), turn \(turnId)")
    let obs = session(sessionId)
    let newDiff = ServerTurnDiff(
      turnId: turnId,
      diff: diff,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens,
      contextWindow: contextWindow,
      snapshotKind: snapshotKind
    )
    var turnDiffs = obs.turnDiffs
    turnDiffs.append(newDiff)
    obs.turnDiffs = normalizedTurnDiffs(turnDiffs, sessionId: sessionId, source: "delta")
  }

  // MARK: - Review Comment Handlers

  private func handleReviewCommentCreated(_ sessionId: String, comment: ServerReviewComment) {
    logger.debug("Review comment created in \(sessionId): \(comment.id)")
    let obs = session(sessionId)
    if !obs.reviewComments.contains(where: { $0.id == comment.id }) {
      obs.reviewComments.append(comment)
    }
  }

  private func handleReviewCommentUpdated(_ sessionId: String, comment: ServerReviewComment) {
    logger.debug("Review comment updated in \(sessionId): \(comment.id)")
    let obs = session(sessionId)
    if let idx = obs.reviewComments.firstIndex(where: { $0.id == comment.id }) {
      obs.reviewComments[idx] = comment
    } else {
      obs.reviewComments.append(comment)
    }
  }

  private func handleReviewCommentDeleted(_ sessionId: String, commentId: String) {
    logger.debug("Review comment deleted in \(sessionId): \(commentId)")
    session(sessionId).reviewComments.removeAll { $0.id == commentId }
  }

  // MARK: - Review Comment Actions

  func createReviewComment(
    sessionId: String,
    turnId: String?,
    filePath: String,
    lineStart: UInt32,
    lineEnd: UInt32?,
    body: String,
    tag: ServerReviewCommentTag?
  ) {
    logger.info("Creating review comment in \(sessionId)")
    connection.createReviewComment(
      sessionId: sessionId,
      turnId: turnId,
      filePath: filePath,
      lineStart: lineStart,
      lineEnd: lineEnd,
      body: body,
      tag: tag
    )
  }

  func updateReviewComment(
    commentId: String,
    body: String?,
    tag: ServerReviewCommentTag?,
    status: ServerReviewCommentStatus?
  ) {
    logger.info("Updating review comment \(commentId)")
    connection.updateReviewComment(commentId: commentId, body: body, tag: tag, status: status)
  }

  func deleteReviewComment(commentId: String) {
    logger.info("Deleting review comment \(commentId)")
    connection.deleteReviewComment(commentId: commentId)
  }

  func listReviewComments(sessionId: String, turnId: String? = nil) {
    connection.listReviewComments(sessionId: sessionId, turnId: turnId)
  }

  // MARK: - Helpers

  private func applyCodexAccountStatus(_ status: ServerCodexAccountStatus) {
    codexAccountStatus = status
    if status.account != nil {
      codexAuthError = nil
    }
  }

  private func markLoginInProgress(loginId: String?) {
    let current = codexAccountStatus
    codexAccountStatus = ServerCodexAccountStatus(
      authMode: current?.authMode,
      requiresOpenaiAuth: current?.requiresOpenaiAuth ?? true,
      account: current?.account,
      loginInProgress: loginId != nil,
      activeLoginId: loginId
    )
  }

  private func openCodexAuthURL(_ authUrl: String) {
    guard let url = URL(string: authUrl) else {
      codexAuthError = "Sign-in URL was invalid."
      return
    }
    let opened = Platform.services.openURL(url)
    if !opened {
      codexAuthError = "Couldn’t open browser for ChatGPT sign-in."
    }
  }

  private func updateSessionInList(_ session: Session) {
    if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[idx] = session
    } else {
      sessions.append(session)
    }
  }

  private func setConfigCache(sessionId: String, approvalPolicy: String?, sandboxMode: String?) {
    if let approvalPolicy {
      approvalPolicies[sessionId] = approvalPolicy
    } else {
      approvalPolicies.removeValue(forKey: sessionId)
    }

    if let sandboxMode {
      sandboxModes[sessionId] = sandboxMode
    } else {
      sandboxModes.removeValue(forKey: sessionId)
    }
  }

  private func trimInactiveSessionPayload(_ sessionId: String, reason: String) {
    guard !subscribedSessions.contains(sessionId) else { return }
    guard let obs = _sessionObservables[sessionId] else { return }

    let messageCount = obs.messages.count
    let turnDiffCount = obs.turnDiffs.count
    guard messageCount > 0 || turnDiffCount > 0 || obs.diff != nil || obs.plan != nil else { return }

    obs.clearConversationPayloadsForCaching()
    lastRevision.removeValue(forKey: sessionId)

    logger.info(
      "Trimmed inactive session payload \(sessionId, privacy: .public) reason=\(reason, privacy: .public) messages=\(messageCount, privacy: .public) turnDiffs=\(turnDiffCount, privacy: .public)"
    )
  }

  private func shouldRequestCodexConnectorData(sessionId: String) -> Bool {
    guard let session = sessions.first(where: { $0.id == sessionId }) else {
      return false
    }
    return session.isActive && session.isDirectCodex
  }

  private static func mockSessions() -> [Session] {
    let now = Date()

    let claude = Session(
      id: "mock-claude-1",
      projectPath: "/Users/demo/Developer/OrbitDock",
      projectName: "OrbitDock",
      branch: "main",
      model: "claude-sonnet-4",
      summary: "Refactor platform abstraction layer",
      status: .active,
      workStatus: .working,
      startedAt: now.addingTimeInterval(-4_200),
      lastActivityAt: now.addingTimeInterval(-20),
      lastTool: "Read",
      promptCount: 12,
      toolCount: 26,
      attentionReason: .none,
      provider: .claude,
      claudeIntegrationMode: .direct
    )

    let codex = Session(
      id: "mock-codex-1",
      projectPath: "/Users/demo/Developer/vizzly",
      projectName: "vizzly",
      branch: "feat/universal-shell",
      model: "gpt-5-codex",
      summary: "Needs approval for apply_patch",
      status: .active,
      workStatus: .permission,
      startedAt: now.addingTimeInterval(-1_800),
      lastActivityAt: now.addingTimeInterval(-90),
      lastTool: "apply_patch",
      promptCount: 5,
      toolCount: 11,
      attentionReason: .awaitingPermission,
      pendingToolName: "apply_patch",
      provider: .codex,
      codexIntegrationMode: .direct
    )

    return [claude, codex]
  }
}

// MARK: - MCP Startup State

/// Tracks per-server MCP startup status for a session
struct McpStartupState {
  /// Per-server startup status
  var serverStatuses: [String: ServerMcpStartupStatus] = [:]

  /// Servers that are ready
  var readyServers: [String] = []

  /// Servers that failed with errors
  var failedServers: [ServerMcpStartupFailure] = []

  /// Servers that were cancelled
  var cancelledServers: [String] = []

  /// Whether startup is complete
  var isComplete: Bool = false
}
