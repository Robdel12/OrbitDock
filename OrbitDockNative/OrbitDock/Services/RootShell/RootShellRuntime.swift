import Foundation

struct RootShellRuntimeUpdate: Sendable {
  let previousMissionControlSessions: [RootSessionNode]
  let currentMissionControlSessions: [RootSessionNode]
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
    }

    if let nextSelectedID {
      await sessionRegistry.promote(nextSelectedID)
    }
  }

  func hotSessionIDsForTesting() async -> Set<String> {
    let snapshot = await sessionRegistry.snapshot()
    return snapshot.hotSessionIDs
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

    Task { [weak self] in
      guard let self else { return }
      let changed = await self.sessionRegistry.apply(event)
      guard changed else { return }
      await self.scheduleSnapshotFlush()
    }
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
        let changed = await self.sessionRegistry.apply(event)
        guard changed else { continue }
        await self.scheduleSnapshotFlush()
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

  private func scheduleSnapshotFlush() async {
    guard pendingFlushTask == nil else { return }

    pendingFlushTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await Task.yield()
      await self.flushSnapshot()
    }
  }

  private func flushSnapshot() async {
    defer { pendingFlushTask = nil }

    let snapshot = await sessionRegistry.snapshot()
    let previousMissionControlSessions = rootShellStore.missionControlRecords()
    let changed = rootShellStore.replace(with: snapshot.state)
    guard changed else { return }

    updatesContinuation.yield(
      RootShellRuntimeUpdate(
        previousMissionControlSessions: previousMissionControlSessions,
        currentMissionControlSessions: snapshot.state.missionControlRecords
      )
    )
  }
}
