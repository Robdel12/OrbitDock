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
  private static let codexModelsCacheKey = "orbitdock.server.codex_models_cache.v1"
  private static let sessionsCacheKey = "orbitdock.server.sessions_cache.v1"

  // MARK: - Observable State (global, not per-session)

  /// Sessions managed by the server (converted to Session model for view compatibility)
  private(set) var sessions: [Session] = []
  private(set) var hasReceivedInitialSessionsList = false

  /// Cross-session approval history (global view)
  private(set) var globalApprovalHistory: [ServerApprovalHistoryItem] = []

  /// Codex models discovered by the server for the current account
  private(set) var codexModels: [ServerCodexModelOption] = []

  /// Current Codex account/auth status (global account state, not per-session)
  private(set) var codexAccountStatus: ServerCodexAccountStatus?

  /// Most recent Codex auth/login error suitable for UI display
  private(set) var codexAuthError: String?

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

  private struct SessionsCachePayload: Codable {
    let cachedAt: Date
    let summaries: [ServerSessionSummary]
  }

  init() {
    if AppRuntimeMode.current == .mock {
      sessions = Self.mockSessions()
      hasReceivedInitialSessionsList = true
      return
    }

    if let cached = loadSessionsCache() {
      sessions = cached.summaries.map { $0.toSession() }
      logger.info("Loaded cached sessions list: \(cached.summaries.count) sessions")
    }

    if let data = UserDefaults.standard.data(forKey: Self.codexModelsCacheKey),
       let models = try? JSONDecoder().decode([ServerCodexModelOption].self, from: data)
    {
      codexModels = models
    }
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
    let conn = ServerConnection.shared

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

    conn.onApprovalRequested = { [weak self] sessionId, request in
      Task { @MainActor in
        self?.handleApprovalRequested(sessionId, request)
      }
    }

    conn.onTokensUpdated = { [weak self] sessionId, usage in
      Task { @MainActor in
        self?.handleTokensUpdated(sessionId, usage)
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

    conn.onClaudeCapabilities = { [weak self] sessionId, slashCommands, skills, tools in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        obs.slashCommands = Set(slashCommands)
        obs.claudeSkillNames = skills
        obs.claudeToolNames = tools
      }
    }

    conn.onSkillsList = { [weak self] sessionId, entries, _ in
      Task { @MainActor in
        let allSkills = entries.flatMap(\.skills)
        self?.session(sessionId).skills = allSkills
      }
    }

    conn.onSkillsUpdateAvailable = { sessionId in
      Task { @MainActor in
        ServerConnection.shared.listSkills(sessionId: sessionId)
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
      }
    }

    conn
      .onTurnDiffSnapshot =
      { [weak self] sessionId, turnId, diff, inputTokens, outputTokens, cachedTokens, contextWindow in
        Task { @MainActor in
          self?.handleTurnDiffSnapshot(
            sessionId,
            turnId: turnId,
            diff: diff,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedTokens: cachedTokens,
            contextWindow: contextWindow
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

    conn.onShellOutput = { [weak self] sessionId, requestId, stdout, stderr, exitCode, durationMs in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        let output = stderr.isEmpty ? stdout : (stdout.isEmpty ? stderr : "\(stdout)\n\(stderr)")
        // Find the shell message to get the command
        let command = obs.messages.first(where: { $0.id == requestId })?.content ?? ""
        obs.bufferShellContext(command: command, output: output, exitCode: exitCode)

        // Update the in-progress shell message with output
        if let idx = obs.messages.firstIndex(where: { $0.id == requestId }) {
          obs.messages[idx].toolOutput = output
          obs.messages[idx].toolDuration = Double(durationMs) / 1_000.0
          obs.messages[idx].isInProgress = false
          obs.bumpMessagesRevision()
        }
      }
    }

    conn.onContextCompacted = { sessionId in
      Task { @MainActor in
        logger.info("Context compacted for \(sessionId)")
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
          userInfo: ["sessionId": newSessionId]
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
      }
    }

    logger.info("ServerAppState callbacks wired")
    refreshCodexModels()
    refreshCodexAccount()
  }

  // MARK: - Actions

  /// Create a new Codex session
  func createSession(cwd: String, model: String? = nil, approvalPolicy: String? = nil, sandboxMode: String? = nil) {
    logger.info("Creating Codex session in \(cwd)")
    let autonomy = AutonomyLevel.from(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode)
    pendingCreationAutonomy = autonomy
    pendingNavigationOnCreate = true
    ServerConnection.shared.createSession(
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
    disallowedTools: [String] = []
  ) {
    logger.info("Creating Claude session in \(cwd)")
    pendingNavigationOnCreate = true
    ServerConnection.shared.createSession(
      provider: .claude,
      cwd: cwd,
      model: model,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: permissionMode,
      allowedTools: allowedTools,
      disallowedTools: disallowedTools
    )
  }

  /// Refresh model options from the server.
  func refreshCodexModels() {
    ServerConnection.shared.listModels()
  }

  /// Refresh global Codex account/auth status.
  func refreshCodexAccount(refreshToken: Bool = false) {
    ServerConnection.shared.readCodexAccount(refreshToken: refreshToken)
  }

  /// Start ChatGPT browser login for Codex.
  func startCodexChatgptLogin() {
    codexAuthError = nil
    ServerConnection.shared.startCodexChatgptLogin()
  }

  /// Cancel an in-progress ChatGPT browser login for Codex.
  func cancelCodexChatgptLogin() {
    guard let loginId = codexActiveLoginId else {
      codexAuthError = "No active sign-in request to cancel."
      return
    }
    ServerConnection.shared.cancelCodexChatgptLogin(loginId: loginId)
  }

  /// Log out the current Codex account.
  func logoutCodexAccount() {
    ServerConnection.shared.logoutCodexAccount()
  }

  /// Refresh the server-authoritative sessions list.
  func refreshSessionsList() {
    ServerConnection.shared.subscribeList()
  }

  private func persistCodexModelsCache(_ models: [ServerCodexModelOption]) {
    if let data = try? JSONEncoder().encode(models) {
      UserDefaults.standard.set(data, forKey: Self.codexModelsCacheKey)
    }
  }

  private func loadSessionsCache() -> SessionsCachePayload? {
    guard let data = UserDefaults.standard.data(forKey: Self.sessionsCacheKey) else {
      return nil
    }

    guard let cached = try? JSONDecoder().decode(SessionsCachePayload.self, from: data) else {
      UserDefaults.standard.removeObject(forKey: Self.sessionsCacheKey)
      return nil
    }

    return cached
  }

  private func persistSessionsCache(_ summaries: [ServerSessionSummary]) {
    let payload = SessionsCachePayload(cachedAt: Date(), summaries: summaries)
    if let data = try? JSONEncoder().encode(payload) {
      UserDefaults.standard.set(data, forKey: Self.sessionsCacheKey)
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
    ServerConnection.shared.sendMessage(
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
    ServerConnection.shared.listSkills(sessionId: sessionId)
  }

  /// Approve or reject a tool with a specific decision
  func approveTool(
    sessionId: String,
    requestId: String,
    decision: String,
    message: String? = nil,
    interrupt: Bool? = nil
  ) {
    logger.info("Approving tool \(requestId) in \(sessionId): \(decision)")

    resolvePendingApprovalLocally(sessionId: sessionId, requestId: requestId, decision: decision)

    ServerConnection.shared.approveTool(
      sessionId: sessionId,
      requestId: requestId,
      decision: decision,
      message: message,
      interrupt: interrupt
    )
    ServerConnection.shared.listApprovals(sessionId: sessionId, limit: 200)
    ServerConnection.shared.listApprovals(sessionId: nil, limit: 200)
  }

  /// Answer a question
  func answerQuestion(sessionId: String, requestId: String, answer: String) {
    logger.info("Answering question \(requestId) in \(sessionId)")
    resolvePendingApprovalLocally(sessionId: sessionId, requestId: requestId, decision: "approved")
    ServerConnection.shared.answerQuestion(sessionId: sessionId, requestId: requestId, answer: answer)
    ServerConnection.shared.listApprovals(sessionId: sessionId, limit: 200)
    ServerConnection.shared.listApprovals(sessionId: nil, limit: 200)
  }

  /// Steer the active turn with additional guidance
  func steerTurn(sessionId: String, content: String) {
    logger.info("Steering turn for \(sessionId)")
    ServerConnection.shared.steerTurn(sessionId: sessionId, content: content)
  }

  /// Compact (summarize) the conversation context
  func compactContext(sessionId: String) {
    logger.info("Compacting context for \(sessionId)")
    ServerConnection.shared.compactContext(sessionId: sessionId)
  }

  /// Undo the last turn (reverts filesystem changes + removes from context)
  func undoLastTurn(sessionId: String) {
    logger.info("Undoing last turn for \(sessionId)")
    ServerConnection.shared.undoLastTurn(sessionId: sessionId)
  }

  /// Roll back N turns from context (does NOT revert filesystem changes)
  func rollbackTurns(sessionId: String, numTurns: UInt32) {
    logger.info("Rolling back \(numTurns) turns for \(sessionId)")
    ServerConnection.shared.rollbackTurns(sessionId: sessionId, numTurns: numTurns)
  }

  /// Fork a session (creates a new session with conversation history)
  func forkSession(sessionId: String, nthUserMessage: UInt32? = nil) {
    logger.info("Forking session \(sessionId) at turn \(nthUserMessage.map(String.init) ?? "full")")
    session(sessionId).forkInProgress = true
    ServerConnection.shared.forkSession(sourceSessionId: sessionId, nthUserMessage: nthUserMessage)
  }

  /// Execute a shell command in a session's working directory (does not trigger AI response)
  func executeShell(sessionId: String, command: String, cwd: String? = nil) {
    logger.info("Executing shell in \(sessionId): \(command)")
    ServerConnection.shared.executeShell(sessionId: sessionId, command: command, cwd: cwd)
  }

  /// Interrupt a session
  func interruptSession(_ sessionId: String) {
    logger.info("Interrupting session \(sessionId)")
    ServerConnection.shared.interruptSession(sessionId)
  }

  /// End a session
  func endSession(_ sessionId: String) {
    logger.info("Ending session \(sessionId)")
    ServerConnection.shared.endSession(sessionId)
  }

  /// Resume an ended session
  func resumeSession(_ sessionId: String) {
    logger.info("Resuming session \(sessionId)")
    subscribedSessions.insert(sessionId)
    ServerConnection.shared.resumeSession(sessionId)
  }

  /// Rename a session
  func renameSession(sessionId: String, name: String?) {
    logger.info("Renaming session \(sessionId) to '\(name ?? "(cleared)")'")
    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].customName = name
    }
    ServerConnection.shared.renameSession(sessionId: sessionId, name: name)
  }

  /// Update session config (change autonomy level mid-session)
  func updateSessionConfig(sessionId: String, autonomy: AutonomyLevel) {
    logger.info("Updating session config \(sessionId) to \(autonomy.displayName)")
    session(sessionId).autonomy = autonomy
    ServerConnection.shared.updateSessionConfig(
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
    ServerConnection.shared.updateSessionConfig(
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
    let sinceRev = lastRevision[sessionId]
    ServerConnection.shared.subscribeSession(sessionId, sinceRevision: sinceRev)
    ServerConnection.shared.listApprovals(sessionId: sessionId, limit: 200)
    logger.debug("Subscribed to session \(sessionId) (sinceRevision: \(sinceRev.map(String.init) ?? "nil"))")
  }

  /// Unsubscribe from a session (called when navigating away)
  func unsubscribeFromSession(_ sessionId: String) {
    subscribedSessions.remove(sessionId)
    ServerConnection.shared.unsubscribeSession(sessionId)
    trimInactiveSessionPayload(sessionId, reason: "unsubscribe")
    logger.debug("Unsubscribed from session \(sessionId)")
  }

  /// Called by app lifecycle when iOS signals memory pressure.
  func handleMemoryPressure() {
    #if os(iOS)
      let inactiveSessionIds = _sessionObservables.keys.filter { !subscribedSessions.contains($0) }
      for sessionId in inactiveSessionIds {
        trimInactiveSessionPayload(sessionId, reason: "memory-pressure")
      }
    #endif
  }

  /// Check if a session ID belongs to a server-managed session
  func isServerSession(_ sessionId: String) -> Bool {
    sessions.contains { $0.id == sessionId }
  }

  /// Load approval history for one session
  func loadApprovalHistory(sessionId: String, limit: Int = 200) {
    ServerConnection.shared.listApprovals(sessionId: sessionId, limit: limit)
  }

  /// Load global approval history across all sessions
  func loadGlobalApprovalHistory(limit: Int = 200) {
    ServerConnection.shared.listApprovals(sessionId: nil, limit: limit)
  }

  /// Delete one approval history item
  func deleteApproval(approvalId: Int64) {
    ServerConnection.shared.deleteApproval(approvalId)
  }

  /// Request subagent tools from the server
  func getSubagentTools(sessionId: String, subagentId: String) {
    ServerConnection.shared.getSubagentTools(sessionId: sessionId, subagentId: subagentId)
  }

  /// List MCP tools for a session
  func listMcpTools(sessionId: String) {
    ServerConnection.shared.listMcpTools(sessionId: sessionId)
  }

  /// Refresh MCP servers for a session
  func refreshMcpServers(sessionId: String) {
    ServerConnection.shared.refreshMcpServers(sessionId: sessionId)
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
    sessions = summaries.map { $0.toSession() }
    for summary in summaries where summary.provider == .codex {
      setConfigCache(sessionId: summary.id, approvalPolicy: summary.approvalPolicy, sandboxMode: summary.sandboxMode)
      session(summary.id).autonomy = AutonomyLevel.from(
        approvalPolicy: summary.approvalPolicy,
        sandboxMode: summary.sandboxMode
      )
    }

    // Clean up observables for sessions that disappeared from the server
    let liveIds = Set(summaries.map(\.id))
    let staleIds = _sessionObservables.keys.filter { !liveIds.contains($0) }
    for id in staleIds {
      _sessionObservables.removeValue(forKey: id)
    }
  }

  private func handleApprovalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem]) {
    let merged = mergeApprovalsPreferResolved(
      existing: sessionId.flatMap { session($0).approvalHistory } ?? globalApprovalHistory,
      incoming: approvals
    )

    if let sessionId {
      session(sessionId).approvalHistory = merged
    } else {
      globalApprovalHistory = merged
    }
  }

  /// Out-of-order websocket responses can deliver an older "pending" snapshot after a
  /// newer resolved one. Prefer already-resolved items when IDs match.
  private func mergeApprovalsPreferResolved(
    existing: [ServerApprovalHistoryItem],
    incoming: [ServerApprovalHistoryItem]
  ) -> [ServerApprovalHistoryItem] {
    let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    let merged = incoming.map { item -> ServerApprovalHistoryItem in
      guard let prior = existingById[item.id] else { return item }
      let priorResolved = prior.decision != nil || prior.decidedAt != nil
      let incomingResolved = item.decision != nil || item.decidedAt != nil
      if priorResolved, !incomingResolved {
        return prior
      }
      return item
    }

    return merged.sorted { $0.id > $1.id }
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

    // Update per-session observable
    let obs = session(state.id)
    let snapshotMessages = state.messages.map { $0.toTranscriptMessage() }
    obs.messages = normalizedTranscriptMessages(snapshotMessages, sessionId: state.id, source: "snapshot")
    obs.bumpMessagesRevision()

    if let approval = state.pendingApproval {
      obs.pendingApproval = approval
    } else {
      obs.pendingApproval = nil
    }

    obs.tokenUsage = state.tokenUsage

    if state.provider == .codex || state.claudeIntegrationMode == .direct {
      setConfigCache(sessionId: state.id, approvalPolicy: state.approvalPolicy, sandboxMode: state.sandboxMode)
      obs.autonomy = AutonomyLevel.from(
        approvalPolicy: state.approvalPolicy,
        sandboxMode: state.sandboxMode
      )
    }

    // Hydrate permission mode from snapshot (stored in approvalPolicy for Claude sessions)
    if state.provider == .claude, state.claudeIntegrationMode == .direct {
      // The server may report permission_mode in the session state — for now, keep
      // whatever the local cache knows, or default.
      if let pm = permissionModes[state.id] {
        obs.permissionMode = ClaudePermissionMode(rawValue: pm) ?? .default
      }
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
    obs.turnDiffs = state.turnDiffs

    // Subagents
    obs.subagents = state.subagents

    // Navigate to newly created session on snapshot (arrives before SessionCreated,
    // so the view gets the full state including integration mode immediately).
    if pendingNavigationOnCreate {
      pendingNavigationOnCreate = false
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": state.id]
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
      sess.status = status == .active ? .active : .ended
    }
    if let workStatus = changes.workStatus {
      sess.workStatus = workStatus.toSessionWorkStatus()
      sess.attentionReason = workStatus.toAttentionReason()
    }
    if let approvalOuter = changes.pendingApproval {
      if let approval = approvalOuter {
        obs.pendingApproval = approval
        sess.pendingApprovalId = approval.id
        sess.pendingToolName = approval.toolNameForDisplay
        sess.pendingToolInput = approval.toolInputForDisplay
        sess.pendingQuestion = approval.question
      } else {
        obs.pendingApproval = nil
        sess.pendingApprovalId = nil
        sess.pendingToolName = nil
        sess.pendingToolInput = nil
        sess.pendingQuestion = nil
      }
    }
    if let usage = changes.tokenUsage {
      obs.tokenUsage = usage
      sess.totalTokens = Int(usage.inputTokens + usage.outputTokens)
      sess.inputTokens = Int(usage.inputTokens)
      sess.outputTokens = Int(usage.outputTokens)
      sess.cachedTokens = Int(usage.cachedTokens)
      sess.contextWindow = Int(usage.contextWindow)
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
      if let name = nameOuter {
        sess.customName = name
      } else {
        sess.customName = nil
      }
    }
    if let summaryOuter = changes.summary {
      if let summaryText = summaryOuter {
        sess.summary = summaryText
      } else {
        sess.summary = nil
      }
    }
    if let firstPromptOuter = changes.firstPrompt {
      if let prompt = firstPromptOuter {
        sess.firstPrompt = prompt
      } else {
        sess.firstPrompt = nil
      }
    }
    if let lastMessageOuter = changes.lastMessage {
      if let message = lastMessageOuter {
        sess.lastMessage = message
      } else {
        sess.lastMessage = nil
      }
    }
    if let modeOuter = changes.codexIntegrationMode {
      if let mode = modeOuter {
        sess.codexIntegrationMode = mode.toSessionMode()
      } else {
        sess.codexIntegrationMode = nil
      }
    }
    if let modeOuter = changes.claudeIntegrationMode {
      if let mode = modeOuter {
        sess.claudeIntegrationMode = mode.toSessionMode()
      } else {
        sess.claudeIntegrationMode = nil
      }
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
    }
    if let shaOuter = changes.gitSha {
      sess.gitSha = shaOuter
    }
    if let cwdOuter = changes.currentCwd {
      sess.currentCwd = cwdOuter
    }
    if let modelOuter = changes.model {
      sess.model = modelOuter
    }
    if let effortOuter = changes.effort {
      sess.effort = effortOuter
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
        sess.lastActivityAt = Date(timeIntervalSince1970: secs)
      }
    }

    sessions[idx] = sess

    // Keep approval history in sync when approval resolves without a manual UI action
    let hasPendingApproval = obs.pendingApproval != nil
    if hadPendingApproval, !hasPendingApproval {
      refreshApprovalHistory(sessionId: sessionId)
      Task { @MainActor in
        for delayMs in [250, 1_000, 2_000] {
          try? await Task.sleep(for: .milliseconds(delayMs))
          refreshApprovalHistory(sessionId: sessionId)
        }
      }
    }
  }

  private func refreshApprovalHistory(sessionId: String) {
    ServerConnection.shared.listApprovals(sessionId: sessionId, limit: 200)
    ServerConnection.shared.listApprovals(sessionId: nil, limit: 200)
  }

  private func resolvePendingApprovalLocally(sessionId: String, requestId: String, decision: String) {
    let decidedAt = ISO8601DateFormatter().string(from: Date())
    let obs = session(sessionId)

    if let pending = obs.pendingApproval, pending.id == requestId {
      obs.pendingApproval = nil

      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        var sess = sessions[idx]
        sess.pendingApprovalId = nil
        sess.pendingToolName = nil
        sess.pendingToolInput = nil
        sess.pendingQuestion = nil
        sess.workStatus = .working
        sess.attentionReason = .none
        sessions[idx] = sess
      }
    }

    let rows = obs.approvalHistory
    if !rows.isEmpty {
      var updatedRows: [ServerApprovalHistoryItem] = []
      for row in rows {
        if row.requestId == requestId, row.decision == nil {
          updatedRows.append(
            ServerApprovalHistoryItem(
              id: row.id,
              sessionId: row.sessionId,
              requestId: row.requestId,
              approvalType: row.approvalType,
              toolName: row.toolName,
              command: row.command,
              filePath: row.filePath,
              cwd: row.cwd,
              decision: decision,
              proposedAmendment: row.proposedAmendment,
              createdAt: row.createdAt,
              decidedAt: decidedAt
            )
          )
        } else {
          updatedRows.append(row)
        }
      }
      obs.approvalHistory = updatedRows
      globalApprovalHistory = globalApprovalHistory.map { item in
        guard item.sessionId == sessionId, item.requestId == requestId, item.decision == nil else { return item }
        return ServerApprovalHistoryItem(
          id: item.id,
          sessionId: item.sessionId,
          requestId: item.requestId,
          approvalType: item.approvalType,
          toolName: item.toolName,
          command: item.command,
          filePath: item.filePath,
          cwd: item.cwd,
          decision: decision,
          proposedAmendment: item.proposedAmendment,
          createdAt: item.createdAt,
          decidedAt: decidedAt
        )
      }
    }
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
      isInProgress: incoming.isInProgress || existing.isInProgress,
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
        isInProgress: false
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
        isInProgress: false
      )
    } else {
      if let output = changes.toolOutput {
        msg.toolOutput = output
      }
      msg.isInProgress = false
    }
    messages[idx] = msg
    obs.messages = normalizedTranscriptMessages(messages, sessionId: sessionId, source: "update")
    obs.bumpMessagesRevision()
  }

  private func handleApprovalRequested(_ sessionId: String, _ request: ServerApprovalRequest) {
    logger.info("Approval requested in \(sessionId): \(request.type.rawValue)")
    session(sessionId).pendingApproval = request
    ServerConnection.shared.listApprovals(sessionId: sessionId, limit: 200)
    ServerConnection.shared.listApprovals(sessionId: nil, limit: 200)

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      var sess = sessions[idx]
      sess.pendingApprovalId = request.id
      sess.pendingToolName = request.toolNameForDisplay
      sess.pendingToolInput = request.toolInputForDisplay
      sess.pendingQuestion = request.question
      sess.attentionReason = request.type == .question ? .awaitingQuestion : .awaitingPermission
      sess.workStatus = .permission
      sessions[idx] = sess
    }
  }

  private func handleTokensUpdated(_ sessionId: String, _ usage: ServerTokenUsage) {
    session(sessionId).tokenUsage = usage

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].totalTokens = Int(usage.inputTokens + usage.outputTokens)
      sessions[idx].inputTokens = Int(usage.inputTokens)
      sessions[idx].outputTokens = Int(usage.outputTokens)
      sessions[idx].cachedTokens = Int(usage.cachedTokens)
      sessions[idx].contextWindow = Int(usage.contextWindow)
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

    if let autonomy = pendingCreationAutonomy {
      session(summary.id).autonomy = autonomy
      pendingCreationAutonomy = nil
    } else if summary.provider == .codex {
      setConfigCache(sessionId: summary.id, approvalPolicy: summary.approvalPolicy, sandboxMode: summary.sandboxMode)
      session(summary.id).autonomy = AutonomyLevel.from(
        approvalPolicy: summary.approvalPolicy,
        sandboxMode: summary.sandboxMode
      )
    }

    subscribeToSession(summary.id)

    // Navigation now handled in handleSessionSnapshot (arrives earlier with full state).
    // Fall back here only if snapshot was missed (e.g. reconnect race).
    if pendingNavigationOnCreate {
      pendingNavigationOnCreate = false
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": summary.id]
      )
    }
  }

  private func handleSessionEnded(_ sessionId: String, _ reason: String) {
    logger.info("Session ended: \(sessionId) (\(reason))")

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].status = .ended
      sessions[idx].workStatus = .unknown
      sessions[idx].attentionReason = .none
    }

    // Clear transient per-session state (keeps messages/tokens/history for viewing)
    session(sessionId).clearTransientState()

    // Clean up internal tracking
    subscribedSessions.remove(sessionId)
    lastRevision.removeValue(forKey: sessionId)
    approvalPolicies.removeValue(forKey: sessionId)
    sandboxModes.removeValue(forKey: sessionId)
    permissionModes.removeValue(forKey: sessionId)
    // Keep SessionObservable alive — user may still be viewing the conversation
  }

  private func handleError(_ code: String, _ message: String, _ sessionId: String?) {
    logger.error("Server error [\(code)]: \(message)")

    if code == "fork_failed" || code == "not_found" {
      if let sid = sessionId {
        session(sid).forkInProgress = false
      }
    }

    // Broadcast subscriber lagged — re-subscribe to get a fresh snapshot
    if code == "lagged", let sid = sessionId {
      logger.info("Re-subscribing to \(sid) after lagged broadcast")
      subscribedSessions.remove(sid)
      subscribeToSession(sid)
    }

    if code.hasPrefix("codex_auth_") {
      codexAuthError = message
      refreshCodexAccount()
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
    contextWindow: UInt64?
  ) {
    logger.debug("Turn diff snapshot for \(sessionId), turn \(turnId)")
    let obs = session(sessionId)
    let newDiff = ServerTurnDiff(
      turnId: turnId,
      diff: diff,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens,
      contextWindow: contextWindow
    )
    if let idx = obs.turnDiffs.firstIndex(where: { $0.turnId == turnId }) {
      obs.turnDiffs[idx] = newDiff
    } else {
      obs.turnDiffs.append(newDiff)
    }
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
    ServerConnection.shared.createReviewComment(
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
    ServerConnection.shared.updateReviewComment(commentId: commentId, body: body, tag: tag, status: status)
  }

  func deleteReviewComment(commentId: String) {
    logger.info("Deleting review comment \(commentId)")
    ServerConnection.shared.deleteReviewComment(commentId: commentId)
  }

  func listReviewComments(sessionId: String, turnId: String? = nil) {
    ServerConnection.shared.listReviewComments(sessionId: sessionId, turnId: turnId)
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
