import Foundation

@MainActor
extension SessionStore {
  func routeEvent(_ event: ServerEvent) {
    switch event {
      case .hello, .dashboardInvalidated, .missionsInvalidated:
        break
      case let .sessionDelta(sessionId, changes):
        handleSessionDelta(sessionId, changes)
      case let .sessionEnded(sessionId, reason):
        handleSessionEnded(sessionId, reason)
      case let .conversationRowsChanged(sessionId, upserted, removedRowIds, totalRowCount):
        handleConversationRowsChanged(sessionId, upserted, removedRowIds, totalRowCount)
      case let .approvalRequested(sessionId, request, version):
        handleApprovalRequested(sessionId, request, version)
      case let .approvalDecisionResult(sessionId, requestId, outcome, activeId, version):
        handleApprovalDecisionResult(sessionId, requestId, outcome, activeId, version)
      case let .approvalsList(sessionId, approvals):
        handleApprovalsList(sessionId, approvals)
      case let .approvalDeleted(approvalId):
        handleApprovalDeleted(approvalId)
      case let .tokensUpdated(sessionId, usage, kind):
        let obs = session(sessionId)
        obs.applyTokenUsage(usage, snapshotKind: kind)
      case let .modelsList(models):
        codexModels = models
      case .claudeModelsList:
        break
      case let .codexAccountStatus(status):
        codexAccountStatus = status
      case let .codexAccountUpdated(status):
        codexAccountStatus = status
      case .codexLoginChatgptStarted, .codexLoginChatgptCompleted, .codexLoginChatgptCanceled:
        break
      case let .skillsList(sessionId, skills, _):
        session(sessionId).skills = skills.flatMap(\.skills)
      case .skillsUpdateAvailable:
        break
      case let .mcpToolsList(sessionId, tools, resources, resourceTemplates, authStatuses):
        let obs = session(sessionId)
        obs.mcpTools = tools
        obs.mcpResources = resources
        obs.mcpResourceTemplates = resourceTemplates
        obs.mcpAuthStatuses = authStatuses
      case let .mcpStartupUpdate(sessionId, server, status):
        let obs = session(sessionId)
        if obs.mcpStartupState == nil {
          obs.mcpStartupState = McpStartupState()
        }
        obs.mcpStartupState?.serverStatuses[server] = status
      case let .mcpStartupComplete(sessionId, ready, failed, cancelled):
        let obs = session(sessionId)
        if obs.mcpStartupState == nil {
          obs.mcpStartupState = McpStartupState()
        }
        obs.mcpStartupState?.isComplete = true
        obs.mcpStartupState?.readyServers = ready
        obs.mcpStartupState?.failedServers = failed
        obs.mcpStartupState?.cancelledServers = cancelled
      case let .claudeCapabilities(sessionId, slashCommands, skills, tools, _):
        let obs = session(sessionId)
        obs.slashCommands = Set(slashCommands)
        obs.claudeSkillNames = skills
        obs.claudeToolNames = tools
      case let .contextCompacted(sessionId):
        let obs = session(sessionId)
        obs.compactInProgress = false
        Task { await self.hydrateSessionFromHTTPBootstrap(sessionId: sessionId) }
      case let .undoStarted(sessionId, message):
        let obs = session(sessionId)
        obs.undoInProgress = true
        if let message {
          netLog(.info, cat: .store, "Undo started", sid: sessionId, data: ["message": message])
        }
      case let .undoCompleted(sessionId, success, _):
        let obs = session(sessionId)
        obs.undoInProgress = false
        if success {
          Task { await self.hydrateSessionFromHTTPBootstrap(sessionId: sessionId) }
        }
      case let .threadRolledBack(sessionId, _):
        session(sessionId).rollbackInProgress = false
        Task { await self.hydrateSessionFromHTTPBootstrap(sessionId: sessionId) }
      case let .sessionForked(sourceSessionId, newSessionId, _):
        let obs = session(sourceSessionId)
        obs.forkInProgress = false
        session(newSessionId).forkedFrom = sourceSessionId
        requestSelection(SessionRef(endpointId: endpointId, sessionId: newSessionId))
      case let .turnDiffSnapshot(sessionId, turnId, diff, input, output, cached, window, kind):
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
      case let .reviewCommentCreated(sessionId, _, comment):
        session(sessionId).reviewComments.append(comment)
      case let .reviewCommentUpdated(sessionId, _, comment):
        let obs = session(sessionId)
        if let idx = obs.reviewComments.firstIndex(where: { $0.id == comment.id }) {
          obs.reviewComments[idx] = comment
        }
      case let .reviewCommentDeleted(sessionId, _, commentId):
        session(sessionId).reviewComments.removeAll { $0.id == commentId }
      case let .reviewCommentsList(sessionId, _, comments):
        session(sessionId).reviewComments = comments
      case let .subagentToolsList(sessionId, subagentId, tools):
        session(sessionId).subagentTools[subagentId] = tools
      case .shellStarted:
        break
      case let .shellOutput(sessionId, _, _, _, _, _, _):
        _ = session(sessionId)
      case let .worktreesList(_, repoRoot, _, worktrees):
        if let root = repoRoot {
          worktreesByRepo[root] = worktrees
        }
      case let .worktreeCreated(_, _, _, worktree):
        let root = worktree.repoRoot
        if worktreesByRepo[root] != nil {
          worktreesByRepo[root]?.append(worktree)
        } else {
          worktreesByRepo[root] = [worktree]
        }
      case let .worktreeRemoved(_, repoRoot, _, worktreeId):
        worktreesByRepo[repoRoot]?.removeAll { $0.id == worktreeId }
      case let .worktreeStatusChanged(worktreeId, status, repoRoot):
        if var wts = worktreesByRepo[repoRoot],
           let idx = wts.firstIndex(where: { $0.id == worktreeId })
        {
          wts[idx].status = status
          worktreesByRepo[repoRoot] = wts
        }
      case .worktreeError:
        break
      case let .rateLimitEvent(sessionId, info):
        session(sessionId).rateLimitInfo = info
      case let .promptSuggestion(sessionId, suggestion):
        session(sessionId).promptSuggestions.append(suggestion)
      case let .filesPersisted(sessionId, _):
        session(sessionId).lastFilesPersistedAt = Date()
      case let .serverInfo(isPrimary, claims):
        serverIsPrimary = isPrimary
        serverPrimaryClaims = claims
      case let .permissionRules(sessionId, rules):
        session(sessionId).permissionRules = rules
      case let .error(code, message, sessionId):
        handleError(code, message, sessionId)
      case let .connectionStatusChanged(status):
        handleConnectionStatusChanged(status)
      case let .missionsList(missions):
        missionListSnapshot = missions
      case let .missionDelta(missionId, issues, summary):
        let obs = mission(missionId)
        obs.summary = summary
        obs.issues = issues
        obs.deltaRevision &+= 1
        obs.lastTickAt = Date()
      case let .missionHeartbeat(missionId, tickStartedAt, nextTickAt):
        let obs = mission(missionId)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        obs.lastTickAt = iso.date(from: tickStartedAt) ?? {
          iso.formatOptions = [.withInternetDateTime]
          return iso.date(from: tickStartedAt)
        }()
        obs.nextTickAt = iso.date(from: nextTickAt) ?? {
          iso.formatOptions = [.withInternetDateTime]
          return iso.date(from: nextTickAt)
        }()
        obs.heartbeatRevision &+= 1
      case let .revision(sessionId, revision):
        lastRevision[sessionId] = revision
      default:
        break
    }
  }

  func eventSummary(_ event: ServerEvent) -> String {
    switch event {
      case .hello: "hello"
      case .dashboardInvalidated: "dashboardInvalidated"
      case .missionsInvalidated: "missionsInvalidated"
      case let .sessionEnded(sid, _): "sessionEnded(\(sid))"
      case let .conversationRowsChanged(sid, upserted, removed, _):
        "conversationRowsChanged(\(sid), +\(upserted.count), -\(removed.count))"
      case let .approvalRequested(sid, _, _): "approvalRequested(\(sid))"
      case let .approvalDecisionResult(sid, rid, outcome, _, _): "approvalResult(\(sid), \(rid), \(outcome))"
      case let .connectionStatusChanged(status): "connectionStatus(\(status))"
      case let .revision(sid, rev): "revision(\(sid), \(rev))"
      case let .error(code, msg, sid): "error(\(code), \(msg), \(sid ?? "nil"))"
      case .missionsList: "missionsList"
      case .missionDelta: "missionDelta"
      case .missionHeartbeat: "missionHeartbeat"
      default: String(describing: event).prefix(80).description
    }
  }

  func handleSessionEnded(_ sessionId: String, _ reason: String) {
    let obs = session(sessionId)
    obs.status = .ended
    obs.workStatus = .ended
    obs.lifecycleState = .ended
    obs.acceptsUserInput = false
    obs.steerable = false
    obs.attentionReason = .none
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
    if let revision = state.revision {
      lastSurfaceRevision[state.id, default: [:]][.conversation] = revision
    }

    subscribedSessions.insert(state.id)
    lastOlderMessagesRequestBeforeSequence.removeValue(forKey: state.id)

    let obs = self.session(state.id)
    obs.applyConversationPage(
      rows: conversation.rows,
      hasMoreBefore: conversation.hasMoreBefore,
      oldestSequence: conversation.oldestSequence,
      isBootstrap: true
    )
    obs.applyServerSnapshot(state)
    let transition = SessionControlStateReducer.snapshotTransition(
      current: controlState(sessionId: state.id, observable: obs),
      snapshot: state,
      supportsServerControlConfiguration: state.provider == .codex || state.claudeIntegrationMode == .direct
    )
    applyControlTransition(transition, sessionId: state.id, observable: obs)
  }

  func handleSessionDetailSnapshot(_ snapshot: ServerSessionDetailSnapshotPayload) {
    lastSurfaceRevision[snapshot.session.id, default: [:]][.detail] = snapshot.revision
    handleSessionSnapshot(snapshot.session)
  }

  func handleSessionComposerSnapshot(_ snapshot: ServerSessionComposerSnapshotPayload) {
    lastSurfaceRevision[snapshot.session.id, default: [:]][.composer] = snapshot.revision
    handleSessionSnapshot(snapshot.session)
  }

  func handleSessionSnapshot(_ state: ServerSessionState) {
    if let rev = state.revision {
      lastRevision[state.id] = rev
    }

    subscribedSessions.insert(state.id)
    let obs = self.session(state.id)
    obs.applyServerSnapshot(state)
    let transition = SessionControlStateReducer.snapshotTransition(
      current: controlState(sessionId: state.id, observable: obs),
      snapshot: state,
      supportsServerControlConfiguration: state.provider == .codex || state.claudeIntegrationMode == .direct
    )
    applyControlTransition(transition, sessionId: state.id, observable: obs)
  }

  func handleSessionDelta(_ sessionId: String, _ changes: ServerStateChanges) {
    let obs = session(sessionId)
    obs.applyServerDelta(changes)

    let summaryStillBlocked = obs.attentionReason == .awaitingPermission || obs.attentionReason == .awaitingQuestion
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
    let obs = session(sessionId)
    obs.applyRowsChanged(upserted: upserted, removedIds: removedRowIds)
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

    if code == "lagged"
      || code == "replay_oversized"
      || code == "session_detail_resync_required"
      || code == "session_composer_resync_required"
      || code == "conversation_resync_required"
    {
      if let sessionId {
        // Session-level lag: re-bootstrap that session
        Task { await self.hydrateSessionFromHTTPBootstrap(sessionId: sessionId) }
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
    connectionGeneration &+= 1
    let generation = connectionGeneration

    netLog(.info, cat: .store, "Connected — re-subscribing session surfaces", data: [
      "generation": generation,
      "subscribedSessionCount": subscribedSessions.count,
    ])

    // Clear stale revision state from previous connection — the HTTP bootstrap
    // will set fresh revisions. Without this, sinceRevision from a dead
    // connection can cause replay_oversized or missed events.
    lastRevision.removeAll()
    lastSurfaceRevision.removeAll()

    // Cancel any in-flight reconnect work from a previous connection cycle.
    // Without this, a flapping connection spawns parallel reconnect Tasks.
    connectionRecoveryTask?.task.cancel()
    connectionRecoveryTask = nil

    let sessionsToResubscribe = subscribedSessions
    let task = Task<Void, Never> {
      for sessionId in sessionsToResubscribe {
        guard !Task.isCancelled else { return }
        await ensureSessionRecovery(sessionId, generation: generation)
      }
    }
    connectionRecoveryTask = GenerationTask(generation: generation, task: task)
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
      case let .set(request):
        observable.applyPendingApproval(request)
      case let .clear(resetAttention):
        observable.clearPendingApprovalDetails(resetAttention: resetAttention)
    }
  }

  func trimInactiveSessionPayload(_ sessionId: String) {
    session(sessionId).trimInactiveDetailPayloads()
  }
}
