import Foundation

@MainActor
extension SessionStore {
  func routeEvent(_ event: ServerEvent) {
    netLog(.debug, cat: .store, "Event: \(eventSummary(event))")
    switch event {
    case .sessionsList(let summaries):
      handleSessionsList(summaries)
    case .sessionCreated(let summary):
      handleSessionCreated(summary)
    case .sessionEnded(let sessionId, let reason):
      handleSessionEnded(sessionId, reason)
    case .sessionSnapshot(let state):
      handleSessionSnapshot(state)
    case .sessionDelta(let sessionId, let changes):
      handleSessionDelta(sessionId, changes)
    case .messageAppended(let sessionId, let message):
      handleMessageAppended(sessionId, message)
    case .messageUpdated(let sessionId, let messageId, let changes):
      handleMessageUpdated(sessionId, messageId, changes)
    case .approvalRequested(let sessionId, let request, let version):
      handleApprovalRequested(sessionId, request, version)
    case .approvalDecisionResult(let sessionId, let requestId, let outcome, let activeId, let version):
      handleApprovalDecisionResult(sessionId, requestId, outcome, activeId, version)
    case .approvalsList(let sessionId, let approvals):
      handleApprovalsList(sessionId, approvals)
    case .approvalDeleted(let approvalId):
      handleApprovalDeleted(approvalId)
    case .tokensUpdated(let sessionId, let usage, let kind):
      let obs = session(sessionId)
      obs.tokenUsage = usage
      obs.tokenUsageSnapshotKind = kind
      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        sessions[idx].inputTokens = Int(usage.inputTokens)
        sessions[idx].outputTokens = Int(usage.outputTokens)
        sessions[idx].cachedTokens = Int(usage.cachedTokens)
        sessions[idx].contextWindow = Int(usage.contextWindow)
        sessions[idx].totalTokens = Int(usage.inputTokens + usage.outputTokens)
        sessions[idx].tokenUsageSnapshotKind = kind
      }
    case .modelsList(let models):
      codexModels = models
    case .claudeModelsList(let models):
      claudeModels = models
    case .codexAccountStatus(let status):
      codexAccountStatus = status
    case .codexAccountUpdated(let status):
      codexAccountStatus = status
    case .codexLoginChatgptStarted, .codexLoginChatgptCompleted, .codexLoginChatgptCanceled:
      break
    case .skillsList(let sessionId, let skills, _):
      session(sessionId).skills = skills.flatMap(\.skills)
    case .remoteSkillsList, .remoteSkillDownloaded, .skillsUpdateAvailable:
      break
    case .mcpToolsList(let sessionId, let tools, let resources, _, let authStatuses):
      let obs = session(sessionId)
      obs.mcpTools = tools
      obs.mcpResources = resources
      obs.mcpAuthStatuses = authStatuses
    case .mcpStartupUpdate(let sessionId, let server, let status):
      let obs = session(sessionId)
      if obs.mcpStartupState == nil {
        obs.mcpStartupState = McpStartupState()
      }
      obs.mcpStartupState?.serverStatuses[server] = status
    case .mcpStartupComplete(let sessionId, let ready, let failed, let cancelled):
      let obs = session(sessionId)
      if obs.mcpStartupState == nil {
        obs.mcpStartupState = McpStartupState()
      }
      obs.mcpStartupState?.isComplete = true
      obs.mcpStartupState?.readyServers = ready
      obs.mcpStartupState?.failedServers = failed
      obs.mcpStartupState?.cancelledServers = cancelled
    case .claudeCapabilities(let sessionId, let slashCommands, let skills, let tools, let models):
      let obs = session(sessionId)
      obs.slashCommands = Set(slashCommands)
      obs.claudeSkillNames = skills
      obs.claudeToolNames = tools
      claudeModels = models
    case .contextCompacted:
      break
    case .undoStarted(let sessionId, let message):
      let obs = session(sessionId)
      obs.undoInProgress = true
      if let message {
        netLog(.info, cat: .store, "Undo started", sid: sessionId, data: ["message": message])
      }
    case .undoCompleted(let sessionId, let success, _):
      let obs = session(sessionId)
      obs.undoInProgress = false
      if success {
        let conv = conversation(sessionId)
        Task { _ = await conv.bootstrap(goal: .completeHistory) }
      }
    case .threadRolledBack(let sessionId, _):
      let conv = conversation(sessionId)
      Task { _ = await conv.bootstrap(goal: .completeHistory) }
    case .sessionForked(let sourceSessionId, let newSessionId, _):
      let obs = session(sourceSessionId)
      obs.forkInProgress = false
      session(newSessionId).forkedFrom = sourceSessionId
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": newSessionId, "endpointId": endpointId]
      )
    case .turnDiffSnapshot(let sessionId, let turnId, let diff, let input, let output, let cached, let window, let kind):
      let obs = session(sessionId)
      let turnDiff = ServerTurnDiff(
        turnId: turnId,
        diff: diff,
        inputTokens: input,
        outputTokens: output,
        cachedTokens: cached,
        contextWindow: window
      )
      if let idx = obs.turnDiffs.firstIndex(where: { $0.turnId == turnId }) {
        obs.turnDiffs[idx] = turnDiff
      } else {
        obs.turnDiffs.append(turnDiff)
      }
      obs.tokenUsageSnapshotKind = kind
      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        sessions[idx].tokenUsageSnapshotKind = kind
        if let input { sessions[idx].inputTokens = Int(input) }
        if let output { sessions[idx].outputTokens = Int(output) }
        if let cached { sessions[idx].cachedTokens = Int(cached) }
        if let window { sessions[idx].contextWindow = Int(window) }
      }
    case .reviewCommentCreated(let sessionId, _, let comment):
      session(sessionId).reviewComments.append(comment)
    case .reviewCommentUpdated(let sessionId, _, let comment):
      let obs = session(sessionId)
      if let idx = obs.reviewComments.firstIndex(where: { $0.id == comment.id }) {
        obs.reviewComments[idx] = comment
      }
    case .reviewCommentDeleted(let sessionId, _, let commentId):
      session(sessionId).reviewComments.removeAll { $0.id == commentId }
    case .reviewCommentsList(let sessionId, _, let comments):
      session(sessionId).reviewComments = comments
    case .subagentToolsList(let sessionId, let subagentId, let tools):
      session(sessionId).subagentTools[subagentId] = tools
    case .shellStarted:
      break
    case .shellOutput(let sessionId, _, _, _, _, _, _):
      _ = session(sessionId)
    case .worktreesList(_, let repoRoot, _, let worktrees):
      if let root = repoRoot {
        worktreesByRepo[root] = worktrees
      }
    case .worktreeCreated(_, _, _, let worktree):
      let root = worktree.repoRoot
      if worktreesByRepo[root] != nil {
        worktreesByRepo[root]?.append(worktree)
      } else {
        worktreesByRepo[root] = [worktree]
      }
    case .worktreeRemoved(_, let repoRoot, _, let worktreeId):
      worktreesByRepo[repoRoot]?.removeAll { $0.id == worktreeId }
    case .worktreeStatusChanged(let worktreeId, let status, let repoRoot):
      if var wts = worktreesByRepo[repoRoot],
         let idx = wts.firstIndex(where: { $0.id == worktreeId }) {
        wts[idx].status = status
        worktreesByRepo[repoRoot] = wts
      }
    case .worktreeError:
      break
    case .rateLimitEvent(let sessionId, let info):
      session(sessionId).rateLimitInfo = info
    case .promptSuggestion(let sessionId, let suggestion):
      session(sessionId).promptSuggestions.append(suggestion)
    case .filesPersisted(let sessionId, _):
      session(sessionId).lastFilesPersistedAt = Date()
    case .serverInfo(let isPrimary, let claims):
      serverIsPrimary = isPrimary
      serverPrimaryClaims = claims
    case .permissionRules(let sessionId, let rules):
      session(sessionId).permissionRules = rules
    case .error(let code, let message, let sessionId):
      handleError(code, message, sessionId)
    case .connectionStatusChanged(let status):
      handleConnectionStatusChanged(status)
    case .revision(let sessionId, let revision):
      lastRevision[sessionId] = revision
    }
  }

  func eventSummary(_ event: ServerEvent) -> String {
    switch event {
    case .sessionsList(let sessions): "sessionsList(\(sessions.count))"
    case .sessionCreated(let s): "sessionCreated(\(s.id))"
    case .sessionEnded(let sid, _): "sessionEnded(\(sid))"
    case .sessionSnapshot(let s): "sessionSnapshot(\(s.id))"
    case .sessionDelta(let sid, _): "sessionDelta(\(sid))"
    case .messageAppended(let sid, let msg): "messageAppended(\(sid), \(msg.id))"
    case .messageUpdated(let sid, let mid, _): "messageUpdated(\(sid), \(mid))"
    case .approvalRequested(let sid, _, _): "approvalRequested(\(sid))"
    case .approvalDecisionResult(let sid, let rid, let outcome, _, _): "approvalResult(\(sid), \(rid), \(outcome))"
    case .connectionStatusChanged(let status): "connectionStatus(\(status))"
    case .revision(let sid, let rev): "revision(\(sid), \(rev))"
    case .error(let code, let msg, let sid): "error(\(code), \(msg), \(sid ?? "nil"))"
    default: String(describing: event).prefix(80).description
    }
  }

  func handleSessionsList(_ summaries: [ServerSessionSummary]) {
    netLog(.info, cat: .store, "Received sessions list", data: ["count": summaries.count])
    hasReceivedInitialSessionsList = true

    let currentById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

    sessions = summaries.map { summary in
      if subscribedSessions.contains(summary.id), let existing = currentById[summary.id] {
        return existing
      }
      var session = summary.toSession()
      session.endpointId = endpointId
      session.endpointName = endpointName
      return session
    }

    for sessionSummary in sessions where !subscribedSessions.contains(sessionSummary.id) {
      hydrateObservable(session(sessionSummary.id), from: sessionSummary)
    }

    let liveIds = Set(summaries.map(\.id))
    let staleIds = _sessionObservables.keys.filter { !liveIds.contains($0) }
    for id in staleIds {
      _sessionObservables.removeValue(forKey: id)
      _conversationStores[id]?.clear()
      _conversationStores.removeValue(forKey: id)
    }

    notifySessionsChanged()
  }

  func handleSessionCreated(_ summary: ServerSessionSummary) {
    var session = summary.toSession()
    session.endpointId = endpointId
    session.endpointName = endpointName
    updateSessionInList(session)
    hydrateObservable(self.session(summary.id), from: session)
  }

  func handleSessionEnded(_ sessionId: String, _ reason: String) {
    let obs = session(sessionId)
    obs.status = .ended
    obs.endReason = reason
    obs.endedAt = Date()
    obs.pendingApproval = nil
    obs.clearTransientState()

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].status = .ended
      sessions[idx].endedAt = Date()
      sessions[idx].clearPendingApprovalSummary(resetAttention: true)
    }
    notifySessionsChanged()
  }

  func handleSessionSnapshot(_ state: ServerSessionState) {
    netLog(.info, cat: .store, "Received snapshot", sid: state.id, data: ["messageCount": state.messages.count])

    if let rev = state.revision {
      lastRevision[state.id] = rev
    }

    subscribedSessions.insert(state.id)

    var session = state.toSession()
    session.customName = state.customName
    updateSessionInList(session)

    let obs = self.session(state.id)
    hydrateObservable(obs, from: session)

    conversation(state.id).handleSnapshot(state)

    obs.pendingApproval = state.pendingApproval
    if let version = state.approvalVersion {
      obs.approvalVersion = version
    }

    obs.tokenUsage = state.tokenUsage
    obs.tokenUsageSnapshotKind = state.tokenUsageSnapshotKind

    if state.provider == .codex || state.claudeIntegrationMode == .direct {
      setConfigCache(
        sessionId: state.id,
        approvalPolicy: state.approvalPolicy,
        sandboxMode: state.sandboxMode
      )
      obs.autonomy = AutonomyLevel.from(
        approvalPolicy: approvalPolicies[state.id],
        sandboxMode: sandboxModes[state.id]
      )
      obs.autonomyConfiguredOnServer = true
    }
    if let pm = state.permissionMode {
      permissionModes[state.id] = pm
      obs.permissionMode = ClaudePermissionMode(rawValue: pm) ?? .default
    }
  }

  func handleSessionDelta(_ sessionId: String, _ changes: ServerStateChanges) {
    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    var session = sessions[idx]
    let obs = self.session(sessionId)

    if let status = changes.status {
      let mapped: Session.SessionStatus = status == .active ? .active : .ended
      session.status = mapped
      obs.status = mapped
    }
    if let workStatus = changes.workStatus {
      let mapped = workStatus.toSessionWorkStatus()
      let attention = workStatus.toAttentionReason()
      session.workStatus = mapped
      session.attentionReason = attention
      obs.workStatus = mapped
      obs.attentionReason = attention
      if mapped == .working {
        obs.promptSuggestions.removeAll()
        obs.rateLimitInfo = nil
      }
    }

    if let approvalOuter = changes.pendingApproval {
      let incomingVersion = changes.approvalVersion ?? 0
      let isStale = incomingVersion > 0 && incomingVersion < obs.approvalVersion
      if !isStale {
        if incomingVersion > 0 { obs.approvalVersion = incomingVersion }
        if let approval = approvalOuter {
          session.applyPendingApprovalSummary(approval)
          obs.applyPendingApproval(approval)
        } else {
          obs.pendingApproval = nil
        }
      }
    }

    if let usage = changes.tokenUsage {
      obs.tokenUsage = usage
      let total = Int(usage.inputTokens + usage.outputTokens)
      session.totalTokens = total
      session.inputTokens = Int(usage.inputTokens)
      session.outputTokens = Int(usage.outputTokens)
      session.cachedTokens = Int(usage.cachedTokens)
      session.contextWindow = Int(usage.contextWindow)
      obs.totalTokens = total
      obs.inputTokens = Int(usage.inputTokens)
      obs.outputTokens = Int(usage.outputTokens)
      obs.cachedTokens = Int(usage.cachedTokens)
      obs.contextWindow = Int(usage.contextWindow)
    }
    if let snapshotKind = changes.tokenUsageSnapshotKind {
      obs.tokenUsageSnapshotKind = snapshotKind
      session.tokenUsageSnapshotKind = snapshotKind
    }

    if let diffOuter = changes.currentDiff {
      obs.diff = diffOuter
      session.currentDiff = diffOuter
    }
    if let planOuter = changes.currentPlan {
      obs.plan = planOuter
    }

    if let val = changes.customName { session.customName = val; obs.customName = val }
    if let val = changes.summary { session.summary = val; obs.summary = val }
    if let val = changes.firstPrompt { session.firstPrompt = val; obs.firstPrompt = val }
    if let val = changes.lastMessage { session.lastMessage = val; obs.lastMessage = val }
    if let modeOuter = changes.codexIntegrationMode {
      let val = modeOuter.flatMap { $0.toSessionMode() }
      session.codexIntegrationMode = val
      obs.codexIntegrationMode = val
    }
    if let modeOuter = changes.claudeIntegrationMode {
      let val = modeOuter.flatMap { $0.toSessionMode() }
      session.claudeIntegrationMode = val
      obs.claudeIntegrationMode = val
    }

    if let approvalOuter = changes.approvalPolicy {
      setConfigCache(sessionId: sessionId, approvalPolicy: approvalOuter, sandboxMode: sandboxModes[sessionId])
    }
    if let sandboxOuter = changes.sandboxMode {
      setConfigCache(sessionId: sessionId, approvalPolicy: approvalPolicies[sessionId], sandboxMode: sandboxOuter)
    }
    if changes.approvalPolicy != nil || changes.sandboxMode != nil {
      obs.autonomy = AutonomyLevel.from(
        approvalPolicy: approvalPolicies[sessionId],
        sandboxMode: sandboxModes[sessionId]
      )
      obs.autonomyConfiguredOnServer = true
    }

    if let turnIdOuter = changes.currentTurnId {
      obs.currentTurnId = turnIdOuter
    }
    if let count = changes.turnCount { obs.turnCount = count }

    if let val = changes.gitBranch { session.branch = val; obs.branch = val }
    if let val = changes.gitSha { session.gitSha = val; obs.gitSha = val }
    if let val = changes.currentCwd { session.currentCwd = val; obs.currentCwd = val }
    if let val = changes.model { session.model = val; obs.model = val }
    if let val = changes.effort { session.effort = val; obs.effort = val }

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
        session.lastActivityAt = date
        obs.lastActivityAt = date
      }
    }

    if let val = changes.repositoryRoot { session.repositoryRoot = val; obs.repositoryRoot = val }
    if let isWt = changes.isWorktree { session.isWorktree = isWt; obs.isWorktree = isWt }
    if let count = changes.unreadCount { session.unreadCount = count; obs.unreadCount = count }

    let summaryStillBlocked = session.attentionReason == .awaitingPermission
      || session.attentionReason == .awaitingQuestion
      || session.workStatus == .permission
    if changes.pendingApproval == nil, !summaryStillBlocked {
      session.clearPendingApprovalSummary(resetAttention: false)
      obs.clearPendingApprovalDetails(resetAttention: false)
    }

    sessions[idx] = session
    notifySessionsChanged()
  }

  func handleMessageAppended(_ sessionId: String, _ message: ServerMessage) {
    netLog(.debug, cat: .store, "Message appended", sid: sessionId, data: ["messageId": message.id])
    conversation(sessionId).handleMessageAppended(message)
    if autoMarkReadSessions.contains(sessionId) {
      markSessionAsRead(sessionId)
    }
  }

  func handleMessageUpdated(_ sessionId: String, _ messageId: String, _ changes: ServerMessageChanges) {
    conversation(sessionId).handleMessageUpdated(messageId: messageId, changes: changes)
  }

  func handleApprovalRequested(_ sessionId: String, _ request: ServerApprovalRequest, _ version: UInt64?) {
    let obs = session(sessionId)
    if let version, version > 0 {
      if version < obs.approvalVersion { return }
      obs.approvalVersion = version
    }
    obs.applyPendingApproval(request)

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].applyPendingApprovalSummary(request)
    }
  }

  func handleApprovalDecisionResult(
    _ sessionId: String,
    _ requestId: String,
    _ outcome: String,
    _ activeRequestId: String?,
    _ version: UInt64
  ) {
    let obs = session(sessionId)
    obs.approvalVersion = version

    if obs.pendingApproval?.id == requestId || obs.pendingApprovalId == requestId, activeRequestId == nil {
      obs.clearPendingApprovalDetails(resetAttention: true)
      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        sessions[idx].clearPendingApprovalSummary(resetAttention: true)
      }
    }

    inFlightApprovalDispatches.remove(requestId)
  }

  func handleApprovalsList(_ sessionId: String?, _ approvals: [ServerApprovalHistoryItem]) {
    if let sessionId {
      session(sessionId).approvalHistory = approvals
    }
  }

  func handleApprovalDeleted(_ approvalId: Int64) {
    for (_, obs) in _sessionObservables {
      obs.approvalHistory.removeAll { $0.id == approvalId }
    }
  }

  func handleError(_ code: String, _ message: String, _ sessionId: String?) {
    netLog(.error, cat: .store, "Server error", sid: sessionId, data: ["code": code, "message": message])

    if code == "lagged" || code == "replay_oversized" {
      if let sessionId {
        let conv = conversation(sessionId)
        Task { await conv.bootstrapFresh() }
      }
      return
    }

    if code == "codex_auth_error" {
      codexAuthError = message
      return
    }

    lastServerError = (code: code, message: message)
  }

  func handleConnectionStatusChanged(_ status: ConnectionStatus) {
    if status == .connected {
      hasReceivedInitialSessionsList = false
      eventStream.subscribeList()
      for sessionId in subscribedSessions {
        eventStream.subscribeSession(
          sessionId,
          sinceRevision: lastRevision[sessionId],
          includeSnapshot: true
        )
      }
    } else if status == .disconnected {
      hasReceivedInitialSessionsList = false
    }
  }

  func hydrateObservable(_ obs: SessionObservable, from session: Session) {
    obs.applySession(session)
  }

  func updateSessionInList(_ session: Session) {
    var stamped = session
    stamped.endpointId = stamped.endpointId ?? endpointId
    stamped.endpointName = stamped.endpointName ?? endpointName
    if let idx = sessions.firstIndex(where: { $0.id == stamped.id }) {
      sessions[idx] = stamped
    } else {
      sessions.append(stamped)
    }
    notifySessionsChanged()
  }

  func notifySessionsChanged() {
    NotificationCenter.default.post(name: .serverSessionsDidChange, object: nil)
  }

  func setConfigCache(sessionId: String, approvalPolicy: String?, sandboxMode: String?) {
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

  func cacheConversationBeforeTrim(sessionId: String) {
    guard let conv = _conversationStores[sessionId], !conv.messages.isEmpty else { return }

    if conversationCache.count >= kConversationCacheMax,
       let oldest = conversationCache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
      conversationCache.removeValue(forKey: oldest)
    }

    conversationCache[sessionId] = conv.cacheSnapshot()
  }

  func trimInactiveSessionPayload(_ sessionId: String) {
    session(sessionId).trimInactiveDetailPayloads()
    _conversationStores[sessionId]?.clear()
  }
}
