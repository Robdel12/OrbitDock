import Foundation

@MainActor
extension SessionStore {
  func routeEvent(_ event: ServerEvent) {
    netLog(.debug, cat: .store, "Event: \(eventSummary(event))")
    switch event {
    case .sessionsList, .sessionCreated, .sessionListItemUpdated, .sessionListItemRemoved:
      break
    case .sessionEnded(let sessionId, let reason):
      handleSessionEnded(sessionId, reason)
    case .conversationBootstrap(let state, let conversation):
      handleConversationBootstrap(state, conversation)
    case .sessionSnapshot(let state):
      handleConversationBootstrap(
        state,
        ServerConversationHistoryPage(
          rows: state.rows,
          totalRowCount: state.totalRowCount ?? UInt64(state.rows.count),
          hasMoreBefore: state.hasMoreBefore ?? false,
          oldestSequence: state.oldestSequence,
          newestSequence: state.newestSequence
        )
      )
    case .sessionDelta(let sessionId, let changes):
      handleSessionDelta(sessionId, changes)
    case .conversationRowsChanged(let sessionId, let upserted, let removedRowIds, let totalRowCount):
      handleConversationRowsChanged(sessionId, upserted, removedRowIds, totalRowCount)
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
    case .mcpToolsList(let sessionId, let tools, let resources, let resourceTemplates, let authStatuses):
      let obs = session(sessionId)
      obs.mcpTools = tools
      obs.mcpResources = resources
      obs.mcpResourceTemplates = resourceTemplates
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
        Task { _ = await conv.bootstrapFresh() }
      }
    case .threadRolledBack(let sessionId, _):
      let conv = conversation(sessionId)
      Task { _ = await conv.bootstrapFresh() }
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
    case .sessionListItemUpdated(let s): "sessionListItemUpdated(\(s.id))"
    case .sessionListItemRemoved(let sid): "sessionListItemRemoved(\(sid))"
    case .sessionEnded(let sid, _): "sessionEnded(\(sid))"
    case .conversationBootstrap(let s, let conversation): "conversationBootstrap(\(s.id), \(conversation.rows.count))"
    case .sessionSnapshot(let s): "sessionSnapshot(\(s.id))"
    case .sessionDelta(let sid, _): "sessionDelta(\(sid))"
    case .conversationRowsChanged(let sid, let upserted, let removed, _):
      "conversationRowsChanged(\(sid), +\(upserted.count), -\(removed.count))"
    case .approvalRequested(let sid, _, _): "approvalRequested(\(sid))"
    case .approvalDecisionResult(let sid, let rid, let outcome, _, _): "approvalResult(\(sid), \(rid), \(outcome))"
    case .connectionStatusChanged(let status): "connectionStatus(\(status))"
    case .revision(let sid, let rev): "revision(\(sid), \(rev))"
    case .error(let code, let msg, let sid): "error(\(code), \(msg), \(sid ?? "nil"))"
    default: String(describing: event).prefix(80).description
    }
  }

  func handleSessionEnded(_ sessionId: String, _ reason: String) {
    let obs = session(sessionId)
    obs.status = .ended
    obs.endReason = reason
    obs.endedAt = Date()
    obs.pendingApproval = nil
    obs.clearTransientState()
    controlStates.removeValue(forKey: sessionId)
  }

  func handleConversationBootstrap(_ state: ServerSessionState, _ conversation: ServerConversationHistoryPage) {
    netLog(.info, cat: .store, "Received bootstrap", sid: state.id, data: ["rowCount": conversation.rows.count])

    if let rev = state.revision {
      lastRevision[state.id] = rev
    }

    subscribedSessions.insert(state.id)

    self.conversation(state.id).handleConversationBootstrap(
      upserted: conversation.rows,
      removedRowIds: [],
      totalRowCount: conversation.totalRowCount,
      hasMoreBefore: conversation.hasMoreBefore,
      oldestSequence: conversation.oldestSequence,
      newestSequence: conversation.newestSequence
    )

    let obs = self.session(state.id)
    obs.applySnapshotProjection(state.toDetailSnapshotProjection())
    obs.subagents = state.subagents
    let transition = SessionControlStateReducer.snapshotTransition(
      current: controlState(sessionId: state.id, observable: obs),
      snapshot: state,
      supportsServerControlConfiguration: state.provider == .codex || state.claudeIntegrationMode == .direct
    )
    applyControlTransition(transition, sessionId: state.id, observable: obs)
  }

  func handleSessionDelta(_ sessionId: String, _ changes: ServerStateChanges) {
    let obs = self.session(sessionId)
    let projection = SessionStateProjection.from(changes)

    obs.applyProjection(projection)
    let summaryStillBlocked = obs.attentionReason == .awaitingPermission
      || obs.attentionReason == .awaitingQuestion
      || obs.workStatus == .permission
    let transition = SessionControlStateReducer.deltaTransition(
      current: controlState(sessionId: sessionId, observable: obs),
      changes: changes,
      summaryStillBlocked: summaryStillBlocked
    )
    applyControlTransition(transition, sessionId: sessionId, observable: obs)
  }

  func handleConversationRowsChanged(
    _ sessionId: String,
    _ upserted: [ServerConversationRowEntry],
    _ removedRowIds: [String],
    _ totalRowCount: UInt64?
  ) {
    conversation(sessionId).handleConversationRowsChanged(
      upserted: upserted,
      removedRowIds: removedRowIds,
      totalRowCount: totalRowCount
    )
    if autoMarkReadSessions.contains(sessionId), !upserted.isEmpty {
      markSessionAsRead(sessionId)
    }
  }

  func handleApprovalRequested(_ sessionId: String, _ request: ServerApprovalRequest, _ version: UInt64?) {
    let obs = session(sessionId)
    guard let transition = SessionControlStateReducer.approvalRequestedTransition(
      current: controlState(sessionId: sessionId, observable: obs),
      request: request,
      version: version
    ) else {
      return
    }
    applyControlTransition(transition, sessionId: sessionId, observable: obs)
  }

  func handleApprovalDecisionResult(
    _ sessionId: String,
    _ requestId: String,
    _ outcome: String,
    _ activeRequestId: String?,
    _ version: UInt64
  ) {
    let obs = session(sessionId)
    let transition = SessionControlStateReducer.approvalDecisionTransition(
      current: controlState(sessionId: sessionId, observable: obs),
      requestId: requestId,
      activeRequestId: activeRequestId,
      version: version
    )
    applyControlTransition(transition, sessionId: sessionId, observable: obs)

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
    guard status == .connected else { return }

    // Re-subscribe list and all active sessions on reconnect
    eventStream.subscribeList()
    for sessionId in subscribedSessions {
      Task {
        let bootstrap = await hydrateSessionFromHTTPBootstrap(sessionId: sessionId)
        eventStream.subscribeSession(
          sessionId,
          sinceRevision: bootstrap?.session.revision,
          includeSnapshot: false
        )
      }
    }
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
    observable: SessionObservable
  ) {
    controlStates[sessionId] = transition.nextState
    observable.approvalVersion = transition.nextState.approvalVersion
    observable.autonomy = transition.nextState.autonomy
    observable.autonomyConfiguredOnServer = transition.nextState.autonomyConfiguredOnServer
    observable.permissionMode = transition.nextState.permissionMode

    applyPendingApprovalChange(transition.approvalChange, to: observable)
  }

  func applyLocalPermissionMode(_ mode: ClaudePermissionMode, sessionId: String) {
    let observable = session(sessionId)
    let transition = SessionControlStateReducer.optimisticPermissionModeTransition(
      current: controlState(sessionId: sessionId, observable: observable),
      mode: mode
    )
    applyControlTransition(transition, sessionId: sessionId, observable: observable)
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

  func trimInactiveSessionPayload(_ sessionId: String) {
    session(sessionId).trimInactiveDetailPayloads()
    _conversationStores[sessionId]?.clear()
  }
}
