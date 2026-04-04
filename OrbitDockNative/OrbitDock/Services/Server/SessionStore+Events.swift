import Foundation

@MainActor
extension SessionStore {
  func routeEvent(_ event: ServerEvent) {
    if routeCodexAccountEvent(event) || routeCapabilitiesEvent(event) || routeWorktreeEvent(event)
      || routeMissionEvent(event)
    {
      return
    }
    switch event {
      case .hello, .dashboardInvalidated, .missionsInvalidated:
        break
      case let .sessionDelta(sessionId, _):
        notifySessionChanged(sessionId)
      case let .sessionEnded(sessionId, _):
        notifySessionChanged(sessionId)
      case let .conversationRowsChanged(sessionId, upserted, removedRowIds, _):
        notifyConversationRowDelta(sessionId, ConversationRowDelta(
          upserted: upserted,
          removedIds: removedRowIds
        ))
      case let .approvalRequested(sessionId, _, _):
        notifySessionChanged(sessionId)
      case let .approvalDecisionResult(sessionId, requestId, _, _, _):
        inFlightApprovalDispatches.remove(requestId)
        notifySessionChanged(sessionId)
      case .approvalsList, .approvalDeleted:
        break
      case let .tokensUpdated(sessionId, _, _):
        notifySessionChanged(sessionId)
      case let .modelsList(models):
        codexModels = models
      case .claudeModelsList:
        break
      case let .contextCompacted(sessionId):
        notifySessionChanged(sessionId)
      case let .undoCompleted(sessionId, _, _):
        notifySessionChanged(sessionId)
      case .undoStarted:
        break
      case let .threadRolledBack(sessionId, _):
        notifySessionChanged(sessionId)
      case let .sessionForked(sourceSessionId, newSessionId, _):
        notifySessionChanged(sourceSessionId)
        requestSelection(SessionRef(endpointId: endpointId, sessionId: newSessionId))
      case let .turnDiffSnapshot(sessionId, _, _, _, _, _, _, _):
        notifySessionChanged(sessionId)
      case let .reviewCommentCreated(sessionId, _, _):
        notifySessionChanged(sessionId)
      case let .reviewCommentUpdated(sessionId, _, _):
        notifySessionChanged(sessionId)
      case let .reviewCommentDeleted(sessionId, _, _):
        notifySessionChanged(sessionId)
      case let .reviewCommentsList(sessionId, _, _):
        notifySessionChanged(sessionId)
      case let .subagentToolsList(sessionId, _, _):
        notifySessionChanged(sessionId)
      case .shellStarted, .shellOutput:
        break
      case let .rateLimitEvent(sessionId, _):
        notifySessionChanged(sessionId)
      case let .promptSuggestion(sessionId, _):
        notifySessionChanged(sessionId)
      case let .filesPersisted(sessionId, _):
        notifySessionChanged(sessionId)
      case let .serverInfo(isPrimary, claims):
        serverIsPrimary = isPrimary
        serverPrimaryClaims = claims
      case let .permissionRules(sessionId, _):
        notifySessionChanged(sessionId)
      case let .error(code, message, sessionId):
        handleError(code, message, sessionId)
      case let .connectionStatusChanged(status):
        handleConnectionStatusChanged(status)
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

    // Deliver bootstrap rows through the conversation row stream so the
    // ConversationViewModel picks them up via its AsyncStream subscription.
    notifyConversationRowDelta(state.id, ConversationRowDelta(
      upserted: conversation.rows,
      removedIds: []
    ))
    notifySessionChanged(state.id)
  }

  func handleSessionDetailSnapshot(_ snapshot: ServerSessionDetailSnapshotPayload) {
    lastSurfaceRevision[snapshot.session.id, default: [:]][.detail] = snapshot.revision
    notifySessionChanged(snapshot.session.id)
  }

  func handleSessionComposerSnapshot(_ snapshot: ServerSessionComposerSnapshotPayload) {
    lastSurfaceRevision[snapshot.session.id, default: [:]][.composer] = snapshot.revision
    notifySessionChanged(snapshot.session.id)
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
        notifySessionChanged(sessionId)
      }
      return
    }

    if code == "codex_auth_error" {
      applyCodexAuthError(message)
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

    lastRevision.removeAll()
    lastSurfaceRevision.removeAll()

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
}
