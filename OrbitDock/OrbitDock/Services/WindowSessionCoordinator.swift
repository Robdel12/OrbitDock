import Foundation

@Observable
@MainActor
final class WindowSessionCoordinator {
  private let runtimeRegistry: ServerRuntimeRegistry
  private let attentionService: AttentionService
  let toastManager: ToastManager
  private let router: AppRouter
  private let unifiedSessionsStore: UnifiedSessionsStore

  private(set) var sessions: [Session] = []

  init(
    runtimeRegistry: ServerRuntimeRegistry,
    attentionService: AttentionService,
    toastManager: ToastManager,
    router: AppRouter
  ) {
    self.runtimeRegistry = runtimeRegistry
    self.attentionService = attentionService
    self.toastManager = toastManager
    self.router = router
    self.unifiedSessionsStore = UnifiedSessionsStore()
  }

  var endpointHealth: [UnifiedEndpointHealth] {
    unifiedSessionsStore.endpointHealth
  }

  var missionControlSessions: [Session] {
    sessions.filter(\.showsInMissionControl)
  }

  var missionControlAttentionSessions: [Session] {
    missionControlSessions.filter(\.needsAttention)
  }

  var isAnyInitialLoading: Bool {
    runtimeRegistry.runtimes
      .filter(\.endpoint.isEnabled)
      .contains { !$0.sessionStore.hasReceivedInitialSessionsList }
  }

  func refreshSessions() {
    let previousMissionControlSessions = missionControlSessions
    let oldWaitingIds = Set(missionControlAttentionSessions.map(\.scopedID))
    let oldSessions = sessions

    unifiedSessionsStore.refresh(from: projectionInputs())
    sessions = unifiedSessionsStore.sessions

    if let selectedScopedID = router.selectedScopedID,
       !unifiedSessionsStore.containsSession(scopedID: selectedScopedID)
    {
      router.goToDashboard()
    }

    let notificationSessions = MissionControlNotificationSessions.merge(
      previousSessions: previousMissionControlSessions,
      currentSessions: sessions
    )

    for session in notificationSessions {
      NotificationManager.shared.updateSessionWorkStatus(session: session)
    }

    for session in missionControlAttentionSessions where !oldWaitingIds.contains(session.scopedID) {
      NotificationManager.shared.notifyNeedsAttention(session: session)
    }

    for oldId in oldWaitingIds where !missionControlAttentionSessions.contains(where: { $0.scopedID == oldId }) {
      NotificationManager.shared.resetNotificationState(for: oldId)
    }

    toastManager.checkForAttentionChanges(
      sessions: missionControlSessions,
      previousSessions: oldSessions.filter(\.showsInMissionControl)
    )

    attentionService.update(sessions: missionControlSessions) { session in
      guard let ref = session.sessionRef else { return nil }
      guard let runtime = self.runtimeRegistry.runtimesByEndpointId[ref.endpointId] else { return nil }
      return runtime.sessionStore.session(ref.sessionId)
    }
  }

  func creationStore(fallback: SessionStore) -> SessionStore {
    let fallbackStore = runtimeRegistry.primarySessionStore(fallback: fallback)
    return runtimeRegistry.sessionStore(
      for: router.selectedEndpointId ?? router.selectedSessionRef?.endpointId,
      fallback: fallbackStore
    )
  }

  func updateToastSelection(currentScopedId: String?) {
    toastManager.currentSessionId = currentScopedId
  }

  func handleExternalSelection(sessionID: String, endpointId: UUID?) {
    router.handleExternalNavigation(
      sessionID: sessionID,
      endpointId: endpointId,
      store: unifiedSessionsStore,
      fallbackEndpointId: runtimeRegistry.primaryEndpointId ?? runtimeRegistry.activeEndpointId
    )
  }

  private func projectionInputs() -> [UnifiedSessionsProjection.EndpointInput] {
    runtimeRegistry.runtimes.map { runtime in
      UnifiedSessionsProjection.EndpointInput(
        endpoint: runtime.endpoint,
        status: runtimeRegistry.connectionStatusByEndpointId[runtime.endpoint.id] ?? .disconnected,
        sessions: runtime.sessionStore.sessions
      )
    }
  }
}
