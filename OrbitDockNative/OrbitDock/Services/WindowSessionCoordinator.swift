import Foundation

@Observable
@MainActor
final class WindowSessionCoordinator {
  private let runtimeRegistry: ServerRuntimeRegistry
  private let attentionService: AttentionService
  private let notificationManager: NotificationManager
  let toastManager: ToastManager
  private let router: AppRouter
  @ObservationIgnored private var selectionObservationTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var rootShellUpdateTask: Task<Void, Never>?
  let rootShellRuntime: RootShellRuntime

  init(
    runtimeRegistry: ServerRuntimeRegistry,
    attentionService: AttentionService,
    notificationManager: NotificationManager,
    toastManager: ToastManager,
    router: AppRouter
  ) {
    self.runtimeRegistry = runtimeRegistry
    self.attentionService = attentionService
    self.notificationManager = notificationManager
    self.toastManager = toastManager
    self.router = router
    self.rootShellRuntime = RootShellRuntime(
      runtimeRegistry: runtimeRegistry,
      rootShellStore: RootShellStore()
    )
  }

  var rootShellStore: RootShellStore { rootShellRuntime.rootShellStore }

  var rootSessions: [RootSessionNode] {
    rootShellStore.records()
  }

  var endpointHealth: [RootShellEndpointHealth] {
    rootShellStore.endpointHealth
  }

  var missionControlSessions: [RootSessionNode] {
    rootSessions.filter(\.showsInMissionControl)
  }

  var missionControlAttentionSessions: [RootSessionNode] {
    missionControlSessions.filter(\.needsAttention)
  }

  var isAnyInitialLoading: Bool {
    runtimeRegistry.runtimes
      .filter(\.endpoint.isEnabled)
      .contains { !$0.eventStream.hasReceivedInitialSessionsList }
  }

  func start(currentScopedId: String?) {
    updateToastSelection(currentScopedId: currentScopedId)
    rootShellRuntime.start()
    observeRootShellUpdatesIfNeeded()
    syncSelectionObservers()
    runtimeRegistry.refreshEnabledSessionLists()
  }

  func runtimeGraphDidChange() {
    rootShellRuntime.runtimeGraphDidChange()
    observeRootShellUpdatesIfNeeded()
    syncSelectionObservers()
  }

  func refreshSessions() {
    if let selectedScopedID = router.selectedScopedID,
       rootShellStore.sessionRef(for: selectedScopedID) == nil
    {
      router.goToDashboard()
    }
  }

  func selectedSessionDidChange(to currentScopedId: String?) {
    updateToastSelection(currentScopedId: currentScopedId)
  }

  private func syncAttentionState(
    previousMissionControlSessions: [RootSessionNode],
    previousSessions: [RootSessionNode]
  ) {
    let oldWaitingIds = Set(previousMissionControlSessions.filter(\.needsAttention).map(\.scopedID))
    let oldSessions = previousSessions

    if let selectedScopedID = router.selectedScopedID,
       rootShellStore.sessionRef(for: selectedScopedID) == nil
    {
      router.goToDashboard()
    }

    let notificationSessions = Self.mergeMissionControlSessions(
      previousSessions: previousMissionControlSessions,
      currentSessions: missionControlSessions
    )

    for session in notificationSessions {
      notificationManager.updateSessionWorkStatus(session: session)
    }

    for session in missionControlAttentionSessions where !oldWaitingIds.contains(session.scopedID) {
      notificationManager.notifyNeedsAttention(session: session)
    }

    for oldId in oldWaitingIds where !missionControlAttentionSessions.contains(where: { $0.scopedID == oldId }) {
      notificationManager.resetNotificationState(for: oldId)
    }

    toastManager.checkForAttentionChanges(
      sessions: missionControlSessions,
      previousSessions: oldSessions.filter(\.showsInMissionControl)
    )

    attentionService.update(sessions: missionControlSessions) { session in
      guard let runtime = self.runtimeRegistry.runtimesByEndpointId[session.endpointId] else { return nil }
      return runtime.sessionStore.session(session.sessionId)
    }
  }

  func syncSelectionObservers() {
    let currentEndpointIds = Set(runtimeRegistry.runtimes.map(\.endpoint.id))

    for endpointId in selectionObservationTasks.keys where !currentEndpointIds.contains(endpointId) {
      selectionObservationTasks[endpointId]?.cancel()
      selectionObservationTasks.removeValue(forKey: endpointId)
    }

    for runtime in runtimeRegistry.runtimes where selectionObservationTasks[runtime.endpoint.id] == nil {
      let store = runtime.sessionStore
      let endpointId = runtime.endpoint.id
      let coordinator = self
      selectionObservationTasks[endpointId] = Task {
        await coordinator.observeSelectionRequests(from: store)
      }
    }
  }

  private func observeRootShellUpdatesIfNeeded() {
    guard rootShellUpdateTask == nil else { return }

    rootShellUpdateTask = Task { [weak self] in
      guard let self else { return }

      for await update in self.rootShellRuntime.updates {
        guard !Task.isCancelled else { break }
        self.syncAttentionState(
          previousMissionControlSessions: update.previousSessions.filter(\.showsInMissionControl),
          previousSessions: update.previousSessions
        )
      }
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
      store: rootShellStore,
      fallbackEndpointId: runtimeRegistry.primaryEndpointId ?? runtimeRegistry.activeEndpointId
    )
  }

  private func observeSelectionRequests(from store: SessionStore) async {
    for await ref in store.selectionRequests {
      guard !Task.isCancelled else { break }
      router.selectSession(ref)
    }
  }

  deinit {
    rootShellUpdateTask?.cancel()
    for task in selectionObservationTasks.values {
      task.cancel()
    }
  }
}
private extension WindowSessionCoordinator {
  static func mergeMissionControlSessions(
    previousSessions: [RootSessionNode],
    currentSessions: [RootSessionNode]
  ) -> [RootSessionNode] {
    var mergedByScopedID: [String: RootSessionNode] = [:]
    var orderedScopedIDs: [String] = []

    for session in currentSessions {
      if mergedByScopedID[session.scopedID] == nil {
        orderedScopedIDs.append(session.scopedID)
      }
      mergedByScopedID[session.scopedID] = session
    }

    for session in previousSessions {
      guard mergedByScopedID[session.scopedID] == nil else { continue }
      mergedByScopedID[session.scopedID] = session
      orderedScopedIDs.append(session.scopedID)
    }

    return orderedScopedIDs.compactMap { mergedByScopedID[$0] }
  }
}
