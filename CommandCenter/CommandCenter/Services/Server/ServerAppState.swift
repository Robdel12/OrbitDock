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

  // MARK: - Observable State (global, not per-session)

  /// Sessions managed by the server (converted to Session model for view compatibility)
  private(set) var sessions: [Session] = []

  /// Cross-session approval history (global view)
  private(set) var globalApprovalHistory: [ServerApprovalHistoryItem] = []

  /// Codex models discovered by the server for the current account
  private(set) var codexModels: [ServerCodexModelOption] = []

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

  /// Full session state cache (from snapshots)
  private var sessionStates: [String: ServerSessionState] = [:]

  /// Track which sessions we're subscribed to
  private var subscribedSessions: Set<String> = []

  /// Temporary: autonomy level from the most recent createSession call
  private var pendingCreationAutonomy: AutonomyLevel?

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.codexModelsCacheKey),
       let models = try? JSONDecoder().decode([ServerCodexModelOption].self, from: data)
    {
      codexModels = models
    }
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

    conn.onSkillsList = { [weak self] sessionId, entries, _ in
      Task { @MainActor in
        let allSkills = entries.flatMap { $0.skills }
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

    conn.onConnected = { [weak self] in
      Task { @MainActor in
        self?.resubscribeAll()
        self?.refreshCodexModels()
      }
    }

    logger.info("ServerAppState callbacks wired")
    refreshCodexModels()
  }

  // MARK: - Actions

  /// Create a new Codex session
  func createSession(cwd: String, model: String? = nil, approvalPolicy: String? = nil, sandboxMode: String? = nil) {
    logger.info("Creating Codex session in \(cwd)")
    let autonomy = AutonomyLevel.from(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode)
    pendingCreationAutonomy = autonomy
    ServerConnection.shared.createSession(
      provider: .codex,
      cwd: cwd,
      model: model,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode
    )
  }

  /// Refresh model options from the server.
  func refreshCodexModels() {
    ServerConnection.shared.listModels()
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

  /// Send a message to a session with optional per-turn overrides, skills, images, and mentions
  func sendMessage(sessionId: String, content: String, model: String? = nil, effort: String? = nil, skills: [ServerSkillInput] = [], images: [ServerImageInput] = [], mentions: [ServerMentionInput] = []) {
    logger.info("Sending message to \(sessionId)")
    ServerConnection.shared.sendMessage(sessionId: sessionId, content: content, model: model, effort: effort, skills: skills, images: images, mentions: mentions)
  }

  /// Request the list of available skills for a session
  func listSkills(sessionId: String) {
    ServerConnection.shared.listSkills(sessionId: sessionId)
  }

  /// Approve or reject a tool with a specific decision
  func approveTool(sessionId: String, requestId: String, decision: String) {
    logger.info("Approving tool \(requestId) in \(sessionId): \(decision)")

    resolvePendingApprovalLocally(sessionId: sessionId, requestId: requestId, decision: decision)

    ServerConnection.shared.approveTool(sessionId: sessionId, requestId: requestId, decision: decision)
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
    logger.debug("Unsubscribed from session \(sessionId)")
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
    sessions = summaries.map { $0.toSession() }
    for summary in summaries where summary.provider == .codex {
      setConfigCache(sessionId: summary.id, approvalPolicy: summary.approvalPolicy, sandboxMode: summary.sandboxMode)
      session(summary.id).autonomy = AutonomyLevel.from(
        approvalPolicy: summary.approvalPolicy,
        sandboxMode: summary.sandboxMode
      )
    }

    // Clean up observables for sessions that disappeared from the server
    let liveIds = Set(summaries.map { $0.id })
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
    sessionStates[state.id] = state

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
    obs.messages = state.messages.map { $0.toTranscriptMessage() }
    obs.bumpMessagesRevision()

    if let approval = state.pendingApproval {
      obs.pendingApproval = approval
    } else {
      obs.pendingApproval = nil
    }

    obs.tokenUsage = state.tokenUsage

    if state.provider == .codex {
      setConfigCache(sessionId: state.id, approvalPolicy: state.approvalPolicy, sandboxMode: state.sandboxMode)
      obs.autonomy = AutonomyLevel.from(
        approvalPolicy: state.approvalPolicy,
        sandboxMode: state.sandboxMode
      )
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
      sess.codexInputTokens = Int(usage.inputTokens)
      sess.codexOutputTokens = Int(usage.outputTokens)
      sess.codexCachedTokens = Int(usage.cachedTokens)
      sess.codexContextWindow = Int(usage.contextWindow)
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
    if let modeOuter = changes.codexIntegrationMode {
      if let mode = modeOuter {
        sess.codexIntegrationMode = mode.toSessionMode()
      } else {
        sess.codexIntegrationMode = nil
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

  private func handleMessageAppended(_ sessionId: String, _ message: ServerMessage) {
    logger.debug("Message appended to \(sessionId): \(message.type.rawValue)")
    let transcriptMsg = message.toTranscriptMessage()
    let obs = session(sessionId)
    var messages = obs.messages

    if let idx = messages.firstIndex(where: { $0.id == transcriptMsg.id }) {
      let existing = messages[idx]
      let merged = TranscriptMessage(
        id: transcriptMsg.id,
        type: transcriptMsg.type,
        content: transcriptMsg.content.isEmpty ? existing.content : transcriptMsg.content,
        timestamp: transcriptMsg.timestamp,
        toolName: transcriptMsg.toolName ?? existing.toolName,
        toolInput: transcriptMsg.toolInput ?? existing.toolInput,
        toolOutput: transcriptMsg.toolOutput ?? existing.toolOutput,
        toolDuration: transcriptMsg.toolDuration ?? existing.toolDuration,
        inputTokens: transcriptMsg.inputTokens ?? existing.inputTokens,
        outputTokens: transcriptMsg.outputTokens ?? existing.outputTokens,
        isInProgress: transcriptMsg.isInProgress || existing.isInProgress
      )
      messages[idx] = merged
    } else {
      messages.append(transcriptMsg)
    }

    obs.messages = messages
    obs.bumpMessagesRevision()
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
      obs.messages = messages
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
    obs.messages = messages
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
      sessions[idx].codexInputTokens = Int(usage.inputTokens)
      sessions[idx].codexOutputTokens = Int(usage.outputTokens)
      sessions[idx].codexCachedTokens = Int(usage.cachedTokens)
      sessions[idx].codexContextWindow = Int(usage.contextWindow)
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
    sessionStates.removeValue(forKey: sessionId)
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
  }

  // MARK: - Helpers

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
