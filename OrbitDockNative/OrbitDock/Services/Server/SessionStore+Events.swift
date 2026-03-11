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
      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        sessions[idx].applyTokenUsage(usage, snapshotKind: kind)
      }
      obs.applyTokenUsage(usage, snapshotKind: kind)
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
      requestSelection(SessionRef(endpointId: endpointId, sessionId: newSessionId))
    case .turnDiffSnapshot(let sessionId, let turnId, let diff, let input, let output, let cached, let window, let kind):
      let obs = session(sessionId)
      let projection = SessionTurnDiffSnapshotProjection.fromTurnDiffSnapshot(
        turnId: turnId,
        diff: diff,
        inputTokens: input,
        outputTokens: output,
        cachedTokens: cached,
        contextWindow: window,
        snapshotKind: kind
      )
      obs.applyTurnDiffSnapshot(projection)
      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        sessions[idx].applyTurnDiffSnapshot(projection)
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
    setHasReceivedInitialSessionsList(true)

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
      controlStates.removeValue(forKey: id)
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
    controlStates.removeValue(forKey: sessionId)
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

    let obs = self.session(state.id)
    hydrateObservable(obs, from: session)
    obs.subagents = state.subagents

    conversation(state.id).handleSnapshot(state)
    let transition = SessionControlStateReducer.snapshotTransition(
      current: controlState(sessionId: state.id, observable: obs),
      snapshot: state,
      supportsServerControlConfiguration: state.provider == .codex || state.claudeIntegrationMode == .direct
    )
    applyControlTransition(transition, sessionId: state.id, session: &session, observable: obs)
    updateSessionInList(session)
  }

  func handleSessionDelta(_ sessionId: String, _ changes: ServerStateChanges) {
    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    var session = sessions[idx]
    let obs = self.session(sessionId)
    let projection = SessionStateProjection.from(changes)

    session.applyProjection(projection)
    obs.applyProjection(projection)
    let summaryStillBlocked = session.attentionReason == .awaitingPermission
      || session.attentionReason == .awaitingQuestion
      || session.workStatus == .permission
    let transition = SessionControlStateReducer.deltaTransition(
      current: controlState(sessionId: sessionId, observable: obs),
      changes: changes,
      summaryStillBlocked: summaryStillBlocked
    )
    applyControlTransition(transition, sessionId: sessionId, session: &session, observable: obs)

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
    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    var session = sessions[idx]
    guard let transition = SessionControlStateReducer.approvalRequestedTransition(
      current: controlState(sessionId: sessionId, observable: obs),
      request: request,
      version: version
    ) else {
      return
    }
    applyControlTransition(transition, sessionId: sessionId, session: &session, observable: obs)
    sessions[idx] = session
  }

  func handleApprovalDecisionResult(
    _ sessionId: String,
    _ requestId: String,
    _ outcome: String,
    _ activeRequestId: String?,
    _ version: UInt64
  ) {
    let obs = session(sessionId)
    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    var session = sessions[idx]
    let transition = SessionControlStateReducer.approvalDecisionTransition(
      current: controlState(sessionId: sessionId, observable: obs),
      requestId: requestId,
      activeRequestId: activeRequestId,
      version: version
    )
    applyControlTransition(transition, sessionId: sessionId, session: &session, observable: obs)
    sessions[idx] = session

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
    guard let plan = SessionFeedPlanner.connectionRecoveryPlan(
      status: status,
      subscribedSessionIds: subscribedSessions,
      sessionHasInitialConversationData: Dictionary(
        uniqueKeysWithValues: subscribedSessions.map { ($0, conversation($0).hasReceivedInitialData) }
      ),
      lastRevisionBySession: lastRevision
    ) else {
      return
    }

    if plan.shouldResetInitialSessionsList {
      setHasReceivedInitialSessionsList(false)
    }

    guard plan.shouldSubscribeList else { return }

    eventStream.subscribeList()
    for request in plan.replayRequests {
      eventStream.subscribeSession(
        request.sessionId,
        sinceRevision: request.sinceRevision,
        includeSnapshot: request.includeSnapshot
      )
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
    emitSessionListUpdate()
  }

  func controlState(sessionId: String, observable: SessionObservable) -> SessionControlState {
    controlStates[sessionId] ?? SessionControlState(
      approvalVersion: observable.approvalVersion,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionModeRaw: observable.permissionMode.rawValue,
      autonomy: observable.autonomy,
      autonomyConfiguredOnServer: observable.autonomyConfiguredOnServer,
      pendingApprovalId: observable.pendingApproval?.id ?? observable.pendingApprovalId
    )
  }

  func applyControlTransition(
    _ transition: SessionControlTransition,
    sessionId: String,
    session: inout Session,
    observable: SessionObservable
  ) {
    controlStates[sessionId] = transition.nextState
    observable.approvalVersion = transition.nextState.approvalVersion
    observable.autonomy = transition.nextState.autonomy
    observable.autonomyConfiguredOnServer = transition.nextState.autonomyConfiguredOnServer
    observable.permissionMode = transition.nextState.permissionMode

    applyPendingApprovalChange(transition.summaryApprovalChange, to: &session)
    applyPendingApprovalChange(transition.detailApprovalChange, to: observable)
  }

  func applyLocalPermissionMode(_ mode: ClaudePermissionMode, sessionId: String) {
    let observable = session(sessionId)
    let transition = SessionControlStateReducer.optimisticPermissionModeTransition(
      current: controlState(sessionId: sessionId, observable: observable),
      mode: mode
    )

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      var session = sessions[idx]
      applyControlTransition(transition, sessionId: sessionId, session: &session, observable: observable)
      sessions[idx] = session
    } else {
      controlStates[sessionId] = transition.nextState
      observable.approvalVersion = transition.nextState.approvalVersion
      observable.autonomy = transition.nextState.autonomy
      observable.autonomyConfiguredOnServer = transition.nextState.autonomyConfiguredOnServer
      observable.permissionMode = transition.nextState.permissionMode
    }
  }

  private func applyPendingApprovalChange(_ change: SessionPendingApprovalChange, to session: inout Session) {
    switch change {
    case .none:
      break
    case .set(let request):
      session.applyPendingApprovalSummary(request)
    case .clear(let resetAttention):
      session.clearPendingApprovalSummary(resetAttention: resetAttention)
    }
  }

  private func applyPendingApprovalChange(_ change: SessionPendingApprovalChange, to observable: SessionObservable) {
    switch change {
    case .none:
      break
    case .set(let request):
      observable.applyPendingApproval(request)
    case .clear(let resetAttention):
      observable.clearPendingApprovalDetails(resetAttention: resetAttention)
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
