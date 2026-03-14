import Foundation

struct RootShellRuntimeUpdate: Sendable {
  let upsertedSessions: [RootSessionNode]
  let removedScopedIDs: [String]
}

@MainActor
final class RootShellRuntime {
  private let runtimeRegistry: ServerRuntimeRegistry
  private let sessionRegistry = SessionRegistry()
  let rootShellStore: RootShellStore
  let updates: AsyncStream<RootShellRuntimeUpdate>

  @ObservationIgnored private let updatesContinuation: AsyncStream<RootShellRuntimeUpdate>.Continuation
  @ObservationIgnored private var rootObservationTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var pendingFlushTask: Task<Void, Never>?
  @ObservationIgnored private var pendingRootEvents: [RootShellEvent] = []
  @ObservationIgnored private var selectedHotSessionID: ScopedSessionID?

  init(runtimeRegistry: ServerRuntimeRegistry, rootShellStore: RootShellStore) {
    self.runtimeRegistry = runtimeRegistry
    self.rootShellStore = rootShellStore

    var continuation: AsyncStream<RootShellRuntimeUpdate>.Continuation!
    updates = AsyncStream { continuation = $0 }
    updatesContinuation = continuation
  }

  convenience init(runtimeRegistry: ServerRuntimeRegistry) {
    self.init(runtimeRegistry: runtimeRegistry, rootShellStore: RootShellStore())
  }

  deinit {
    updatesContinuation.finish()
    pendingFlushTask?.cancel()
    for task in rootObservationTasks.values {
      task.cancel()
    }
  }

  func start() {
    runtimeGraphDidChange()
  }

  func runtimeGraphDidChange() {
    let currentEndpointIds = Set(runtimeRegistry.runtimes.map(\.endpoint.id))

    for endpointId in rootObservationTasks.keys where !currentEndpointIds.contains(endpointId) {
      rootObservationTasks[endpointId]?.cancel()
      rootObservationTasks.removeValue(forKey: endpointId)
    }

    for runtime in runtimeRegistry.runtimes where rootObservationTasks[runtime.endpoint.id] == nil {
      bootstrapRootShell(from: runtime)
      observeRootShellEvents(from: runtime)
    }
  }

  func selectedSessionDidChange(to scopedID: String?) {
    Task { [weak self] in
      await self?.applySelectedSessionChange(to: scopedID)
    }
  }

  func applySelectedSessionChange(to scopedID: String?) async {
    let nextSelectedID = scopedID.flatMap(ScopedSessionID.init(scopedID:))
    guard nextSelectedID != selectedHotSessionID else { return }

    let previousSelectedID = selectedHotSessionID
    selectedHotSessionID = nextSelectedID

    if let previousSelectedID {
      await sessionRegistry.demote(previousSelectedID)
      demoteHotDetailResidency(for: previousSelectedID)
    }

    if let nextSelectedID {
      await sessionRegistry.promote(nextSelectedID)
      promoteHotDetailResidency(for: nextSelectedID)
    }
  }

  func hotSessionIDsForTesting() async -> Set<String> {
    await sessionRegistry.hotSessionIDsSnapshot()
  }

  private func bootstrapRootShell(from runtime: ServerRuntime) {
    let eventStream = runtime.eventStream
    guard eventStream.hasReceivedInitialSessionsList else { return }
    let event = RootShellEvent.sessionsList(
      endpointId: runtime.endpoint.id,
      endpointName: runtime.endpoint.name,
      connectionStatus: runtimeRegistry.displayConnectionStatus(for: runtime.endpoint.id),
      sessions: eventStream.latestSessionListItems
    )

    enqueueRootEvent(event)
  }

  private func promoteHotDetailResidency(for scopedID: ScopedSessionID) {
    let store = runtimeRegistry.sessionStore(
      for: scopedID.endpointId,
      fallback: runtimeRegistry.activeSessionStore
    )
    store.promoteHotDetailResidency(for: scopedID.sessionId)
  }

  private func demoteHotDetailResidency(for scopedID: ScopedSessionID) {
    let store = runtimeRegistry.sessionStore(
      for: scopedID.endpointId,
      fallback: runtimeRegistry.activeSessionStore
    )
    store.demoteHotDetailResidency(for: scopedID.sessionId)
  }

  private func observeRootShellEvents(from runtime: ServerRuntime) {
    let eventStream = runtime.eventStream
    let endpointId = runtime.endpoint.id

    rootObservationTasks[endpointId] = Task { [weak self] in
      guard let self else { return }

      for await serverEvent in eventStream.rootEvents {
        guard !Task.isCancelled else { break }
        guard let event = self.rootShellEvent(
          from: serverEvent,
          runtime: runtime
        ) else { continue }
        self.enqueueRootEvent(event)
      }
    }
  }

  private func rootShellEvent(
    from event: ServerEvent,
    runtime: ServerRuntime
  ) -> RootShellEvent? {
    let endpointId = runtime.endpoint.id
    let endpointName = runtime.endpoint.name
    let connectionStatus = runtimeRegistry.displayConnectionStatus(for: endpointId)

    switch event {
      case let .sessionsList(sessions):
        return .sessionsList(
          endpointId: endpointId,
          endpointName: endpointName,
          connectionStatus: connectionStatus,
          sessions: sessions
        )
      case let .sessionCreated(session):
        return .sessionCreated(
          endpointId: endpointId,
          endpointName: endpointName,
          connectionStatus: connectionStatus,
          session: session
        )
      case let .sessionListItemUpdated(session):
        return .sessionUpdated(
          endpointId: endpointId,
          endpointName: endpointName,
          connectionStatus: connectionStatus,
          session: session
        )
      case let .sessionListItemRemoved(sessionId):
        return .sessionRemoved(
          endpointId: endpointId,
          sessionId: sessionId
        )
      case let .sessionEnded(sessionId, reason):
        return .sessionEnded(
          endpointId: endpointId,
          sessionId: sessionId,
          reason: reason
        )
      case let .connectionStatusChanged(status):
        return .endpointConnectionChanged(
          endpointId: endpointId,
          endpointName: endpointName,
          connectionStatus: status
        )
      default:
        return nil
    }
  }

  private func enqueueRootEvent(_ event: RootShellEvent) {
    pendingRootEvents.append(event)
    scheduleSnapshotFlush()
  }

  private func scheduleSnapshotFlush() {
    guard pendingFlushTask == nil else { return }

    pendingFlushTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await Task.yield()
      self.flushSnapshot()
    }
  }

  private func flushSnapshot() {
    defer { pendingFlushTask = nil }
    let events = RootShellEventCoalescer.coalesce(pendingRootEvents)
    pendingRootEvents.removeAll(keepingCapacity: true)
    guard !events.isEmpty else { return }

    let changeSet = rootShellStore.apply(events)
    guard changeSet.didChange else { return }

    let upsertedSessions = changeSet.upsertedScopedIDs.compactMap { scopedID in
      rootShellStore.record(for: scopedID)
    }

    updatesContinuation.yield(
      RootShellRuntimeUpdate(
        upsertedSessions: upsertedSessions,
        removedScopedIDs: changeSet.removedScopedIDs
      )
    )
  }
}
