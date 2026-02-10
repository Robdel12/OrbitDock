//
//  ServerAppState.swift
//  OrbitDock
//
//  WebSocket-backed state store for server-managed sessions.
//  Listens to ServerConnection callbacks and maintains Session/TranscriptMessage
//  state that views can observe. Equivalent to SessionStore but for Codex sessions
//  flowing through the Rust server.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "server-app-state")

@Observable
@MainActor
final class ServerAppState {
  private static let codexModelsCacheKey = "orbitdock.server.codex_models_cache.v1"

  // MARK: - Observable State

  /// Sessions managed by the server (converted to Session model for view compatibility)
  private(set) var sessions: [Session] = []

  /// Messages per session (converted to TranscriptMessage for view compatibility)
  private(set) var sessionMessages: [String: [TranscriptMessage]] = [:]

  /// Pending approval requests per session
  private(set) var pendingApprovals: [String: ServerApprovalRequest] = [:]

  /// Token usage per session
  private(set) var tokenUsage: [String: ServerTokenUsage] = [:]

  /// Diff per session (aggregated turn diff)
  private(set) var sessionDiffs: [String: String] = [:]

  /// Plan per session (JSON string)
  private(set) var sessionPlans: [String: String] = [:]

  /// Approval history per session
  private(set) var approvalHistoryBySession: [String: [ServerApprovalHistoryItem]] = [:]

  /// Cross-session approval history (global view)
  private(set) var globalApprovalHistory: [ServerApprovalHistoryItem] = []

  /// Revision counter per session - incremented on message append/update for change tracking
  private(set) var messageRevisions: [String: Int] = [:]

  /// Current autonomy level per session
  private(set) var currentAutonomy: [String: AutonomyLevel] = [:]

  /// Codex models discovered by the server for the current account
  private(set) var codexModels: [ServerCodexModelOption] = []

  /// Raw config values used to derive autonomy accurately across partial deltas
  private var approvalPolicies: [String: String] = [:]
  private var sandboxModes: [String: String] = [:]

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.codexModelsCacheKey),
       let models = try? JSONDecoder().decode([ServerCodexModelOption].self, from: data)
    {
      codexModels = models
    }
  }

  // MARK: - Internal State

  /// Full session state cache (from snapshots)
  private var sessionStates: [String: ServerSessionState] = [:]

  /// Track which sessions we're subscribed to
  private var subscribedSessions: Set<String> = []

  /// Temporary: autonomy level from the most recent createSession call
  private var pendingCreationAutonomy: AutonomyLevel?

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
    // Track the initial autonomy level so we can show it in the UI
    let autonomy = AutonomyLevel.from(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode)
    pendingCreationAutonomy = autonomy
    ServerConnection.shared.createSession(provider: .codex, cwd: cwd, model: model, approvalPolicy: approvalPolicy, sandboxMode: sandboxMode)
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

  /// Send a message to a session with optional per-turn overrides
  func sendMessage(sessionId: String, content: String, model: String? = nil, effort: String? = nil) {
    logger.info("Sending message to \(sessionId)")
    ServerConnection.shared.sendMessage(sessionId: sessionId, content: content, model: model, effort: effort)
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
    currentAutonomy[sessionId] = autonomy
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
    ServerConnection.shared.subscribeSession(sessionId)
    ServerConnection.shared.listApprovals(sessionId: sessionId, limit: 200)
    logger.debug("Subscribed to session \(sessionId)")
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
      currentAutonomy[summary.id] = AutonomyLevel.from(
        approvalPolicy: summary.approvalPolicy,
        sandboxMode: summary.sandboxMode
      )
    }
  }

  private func handleApprovalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem]) {
    let merged = mergeApprovalsPreferResolved(
      existing: sessionId.flatMap { approvalHistoryBySession[$0] } ?? globalApprovalHistory,
      incoming: approvals
    )

    if let sessionId {
      approvalHistoryBySession[sessionId] = merged
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
      if priorResolved && !incomingResolved {
        return prior
      }
      return item
    }

    return merged.sorted { $0.id > $1.id }
  }

  private func handleApprovalDeleted(approvalId: Int64) {
    globalApprovalHistory.removeAll { $0.id == approvalId }
    for key in approvalHistoryBySession.keys {
      approvalHistoryBySession[key]?.removeAll { $0.id == approvalId }
    }
  }

  private func handleSessionSnapshot(_ state: ServerSessionState) {
    logger.info("Received snapshot for \(state.id): \(state.messages.count) messages")
    sessionStates[state.id] = state

    // Mark as subscribed (server pre-subscribes creator on CreateSession)
    subscribedSessions.insert(state.id)

    // Update session in list
    var session = state.toSession()
    session.customName = state.customName
    updateSessionInList(session)

    // Store messages
    sessionMessages[state.id] = state.messages.map { $0.toTranscriptMessage() }
    messageRevisions[state.id, default: 0] += 1

    // Store approval if present
    if let approval = state.pendingApproval {
      pendingApprovals[state.id] = approval
    } else {
      pendingApprovals.removeValue(forKey: state.id)
    }

    // Store token usage
    tokenUsage[state.id] = state.tokenUsage

    if state.provider == .codex {
      setConfigCache(sessionId: state.id, approvalPolicy: state.approvalPolicy, sandboxMode: state.sandboxMode)
      currentAutonomy[state.id] = AutonomyLevel.from(
        approvalPolicy: state.approvalPolicy,
        sandboxMode: state.sandboxMode
      )
    }

    // Store diff/plan
    if let diff = state.currentDiff {
      sessionDiffs[state.id] = diff
    }
    if let plan = state.currentPlan {
      sessionPlans[state.id] = plan
    }
  }

  private func handleSessionDelta(_ sessionId: String, _ changes: ServerStateChanges) {
    logger.debug("Session delta for \(sessionId)")

    // Find and update the session
    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    var session = sessions[idx]
    let hadPendingApproval = pendingApprovals[sessionId] != nil

    if let status = changes.status {
      session.status = status == .active ? .active : .ended
    }
    if let workStatus = changes.workStatus {
      session.workStatus = workStatus.toSessionWorkStatus()
      session.attentionReason = workStatus.toAttentionReason()
    }
    // Handle optional-optional for pendingApproval (nil = unchanged, .some(nil) = cleared)
    if let approvalOuter = changes.pendingApproval {
      if let approval = approvalOuter {
        pendingApprovals[sessionId] = approval
        session.pendingApprovalId = approval.id
        session.pendingToolName = approval.toolNameForDisplay
        session.pendingToolInput = approval.toolInputForDisplay
        session.pendingQuestion = approval.question
      } else {
        pendingApprovals.removeValue(forKey: sessionId)
        session.pendingApprovalId = nil
        session.pendingToolName = nil
        session.pendingToolInput = nil
        session.pendingQuestion = nil
      }
    }
    if let usage = changes.tokenUsage {
      tokenUsage[sessionId] = usage
      session.codexInputTokens = Int(usage.inputTokens)
      session.codexOutputTokens = Int(usage.outputTokens)
      session.codexCachedTokens = Int(usage.cachedTokens)
      session.codexContextWindow = Int(usage.contextWindow)
    }
    // Handle optional-optional for diff
    if let diffOuter = changes.currentDiff {
      if let diff = diffOuter {
        sessionDiffs[sessionId] = diff
        session.currentDiff = diff
      } else {
        sessionDiffs.removeValue(forKey: sessionId)
        session.currentDiff = nil
      }
    }
    // Handle optional-optional for plan
    if let planOuter = changes.currentPlan {
      if let plan = planOuter {
        sessionPlans[sessionId] = plan
      } else {
        sessionPlans.removeValue(forKey: sessionId)
      }
    }
    // Handle optional-optional for custom name
    if let nameOuter = changes.customName {
      if let name = nameOuter {
        session.customName = name
      } else {
        session.customName = nil
      }
    }
    if let modeOuter = changes.codexIntegrationMode {
      if let mode = modeOuter {
        session.codexIntegrationMode = mode.toSessionMode()
      } else {
        session.codexIntegrationMode = nil
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
      currentAutonomy[sessionId] = AutonomyLevel.from(approvalPolicy: approval, sandboxMode: sandbox)
    }
    if let lastActivity = changes.lastActivityAt {
      // Parse and update
      let stripped = lastActivity.hasSuffix("Z") ? String(lastActivity.dropLast()) : lastActivity
      if let secs = TimeInterval(stripped) {
        session.lastActivityAt = Date(timeIntervalSince1970: secs)
      }
    }

    sessions[idx] = session

    // Keep approval history in sync when approval resolves without a manual UI action
    // (e.g. session/global allow rules auto-approve a matching command).
    let hasPendingApproval = pendingApprovals[sessionId] != nil
    if hadPendingApproval && !hasPendingApproval {
      refreshApprovalHistory(sessionId: sessionId)
      // Persistence writes are batched server-side; issue a few bounded retries
      // so just-resolved approvals don't remain visually stuck as "pending".
      Task { @MainActor in
        for delayMs in [250, 1000, 2000] {
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

    // Clear local pending gate immediately once user has decided.
    if let pending = pendingApprovals[sessionId], pending.id == requestId {
      pendingApprovals.removeValue(forKey: sessionId)

      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        var session = sessions[idx]
        session.pendingApprovalId = nil
        session.pendingToolName = nil
        session.pendingToolInput = nil
        session.pendingQuestion = nil
        session.workStatus = .working
        session.attentionReason = .none
        sessions[idx] = session
      }
    }

    // Optimistically mark matching history row(s) as decided so chips do not stick on "pending".
    if var rows = approvalHistoryBySession[sessionId] {
      var updatedRows: [ServerApprovalHistoryItem] = []
      for row in rows {
        if row.requestId == requestId && row.decision == nil {
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
      approvalHistoryBySession[sessionId] = updatedRows
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
    var messages = sessionMessages[sessionId] ?? []

    if let idx = messages.firstIndex(where: { $0.id == transcriptMsg.id }) {
      // Streaming edge case: update can arrive before append.
      // Merge to avoid duplicate IDs in ForEach, which can cause stale render frames.
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

    sessionMessages[sessionId] = messages
    messageRevisions[sessionId, default: 0] += 1
    reactivateSessionOnNewMessageIfNeeded(sessionId)
  }

  private func handleMessageUpdated(_ sessionId: String, _ messageId: String, _ changes: ServerMessageChanges) {
    logger.debug("Message updated in \(sessionId): \(messageId)")

    var messages = sessionMessages[sessionId] ?? []

    guard let idx = messages.firstIndex(where: { $0.id == messageId }) else {
      // Streaming edge case: we can receive an update before create (or with a remapped ID).
      // Upsert an assistant message so content isn't dropped in the UI.
      guard let content = changes.content else { return }
      let fallback = TranscriptMessage(
        id: messageId,
        type: .assistant,
        content: content,
        timestamp: Date(),
        toolName: nil,
        toolInput: nil,
        toolOutput: changes.toolOutput,
        toolDuration: changes.durationMs.map { Double($0) / 1000.0 },
        inputTokens: nil,
        outputTokens: nil,
        isInProgress: false
      )
      messages.append(fallback)
      sessionMessages[sessionId] = messages
      messageRevisions[sessionId, default: 0] += 1
      logger.warning("Message update arrived before create; upserted \(messageId) in \(sessionId)")
      return
    }

    var msg = messages[idx]
    if let content = changes.content {
      // TranscriptMessage.content is let, so we need to create a new one
      msg = TranscriptMessage(
        id: msg.id,
        type: msg.type,
        content: content,
        timestamp: msg.timestamp,
        toolName: msg.toolName,
        toolInput: msg.toolInput,
        toolOutput: changes.toolOutput ?? msg.toolOutput,
        toolDuration: changes.durationMs.map { Double($0) / 1000.0 } ?? msg.toolDuration,
        inputTokens: msg.inputTokens,
        outputTokens: msg.outputTokens,
        isInProgress: false
      )
    } else {
      // Only updating mutable fields
      if let output = changes.toolOutput {
        msg.toolOutput = output
      }
      msg.isInProgress = false
    }
    messages[idx] = msg
    sessionMessages[sessionId] = messages
    messageRevisions[sessionId, default: 0] += 1
    reactivateSessionOnNewMessageIfNeeded(sessionId)
  }

  private func handleApprovalRequested(_ sessionId: String, _ request: ServerApprovalRequest) {
    logger.info("Approval requested in \(sessionId): \(request.type.rawValue)")
    pendingApprovals[sessionId] = request
    ServerConnection.shared.listApprovals(sessionId: sessionId, limit: 200)
    ServerConnection.shared.listApprovals(sessionId: nil, limit: 200)

    // Update session state
    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      var session = sessions[idx]
      session.pendingApprovalId = request.id
      session.pendingToolName = request.toolNameForDisplay
      session.pendingToolInput = request.toolInputForDisplay
      session.pendingQuestion = request.question
      session.attentionReason = request.type == .question ? .awaitingQuestion : .awaitingPermission
      session.workStatus = .permission
      sessions[idx] = session
    }
  }

  private func handleTokensUpdated(_ sessionId: String, _ usage: ServerTokenUsage) {
    tokenUsage[sessionId] = usage

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].codexInputTokens = Int(usage.inputTokens)
      sessions[idx].codexOutputTokens = Int(usage.outputTokens)
      sessions[idx].codexCachedTokens = Int(usage.cachedTokens)
      sessions[idx].codexContextWindow = Int(usage.contextWindow)
    }
  }

  private func handleSessionCreated(_ summary: ServerSessionSummary) {
    logger.info("Session created: \(summary.id)")
    let session = summary.toSession()

    // Upsert summary. Rollout watcher uses session_created as a list-level
    // upsert for passive sessions (including ended -> active reactivation).
    if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[idx] = session
    } else {
      sessions.append(session)
    }

    // Set autonomy level from creation or from summary payload.
    if let autonomy = pendingCreationAutonomy {
      currentAutonomy[summary.id] = autonomy
      pendingCreationAutonomy = nil
    } else if summary.provider == .codex {
      setConfigCache(sessionId: summary.id, approvalPolicy: summary.approvalPolicy, sandboxMode: summary.sandboxMode)
      currentAutonomy[summary.id] = AutonomyLevel.from(
        approvalPolicy: summary.approvalPolicy,
        sandboxMode: summary.sandboxMode
      )
    }

    // Auto-subscribe to get detailed updates
    subscribeToSession(summary.id)
  }

  /// Defensive reactivation: if we are receiving live messages for a session that is
  /// currently ended in UI state, flip it back to active immediately.
  /// This covers edge cases where message stream arrives before explicit lifecycle delta.
  private func reactivateSessionOnNewMessageIfNeeded(_ sessionId: String) {
    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    guard sessions[idx].status != .active else { return }

    sessions[idx].status = .active
    if sessions[idx].workStatus == .unknown {
      sessions[idx].workStatus = .waiting
    }
  }

  private func handleSessionEnded(_ sessionId: String, _ reason: String) {
    logger.info("Session ended: \(sessionId) (\(reason))")

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].status = .ended
      sessions[idx].workStatus = .waiting
      sessions[idx].attentionReason = .none
    }

    pendingApprovals.removeValue(forKey: sessionId)
    subscribedSessions.remove(sessionId)
    approvalPolicies.removeValue(forKey: sessionId)
    sandboxModes.removeValue(forKey: sessionId)
    currentAutonomy.removeValue(forKey: sessionId)
  }

  private func handleError(_ code: String, _ message: String, _ sessionId: String?) {
    logger.error("Server error [\(code)]: \(message)")
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

  /// Parse plan JSON string into PlanStep array for UI
  func getPlanSteps(sessionId: String) -> [Session.PlanStep]? {
    guard let json = sessionPlans[sessionId],
          let data = json.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }

    let steps = array.compactMap { dict -> Session.PlanStep? in
      guard let step = dict["step"] as? String else { return nil }
      let status = dict["status"] as? String ?? "pending"
      return Session.PlanStep(step: step, status: status)
    }
    return steps.isEmpty ? nil : steps
  }

  /// Get diff for a session
  func getDiff(sessionId: String) -> String? {
    sessionDiffs[sessionId]
  }
}
