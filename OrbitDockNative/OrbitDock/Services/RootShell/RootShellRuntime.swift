import Foundation

struct RootShellRuntimeUpdate: Sendable {
  let previousSessions: [RootSessionNode]
  let currentSessions: [RootSessionNode]
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

  private func bootstrapRootShell(from runtime: ServerRuntime) {
    let store = runtime.sessionStore
    guard store.hasReceivedInitialSessionsList else { return }
    let event = RootShellEvent.sessionsList(
      endpointId: runtime.endpoint.id,
      endpointName: runtime.endpoint.name,
      connectionStatus: runtimeRegistry.displayConnectionStatus(for: runtime.endpoint.id),
      sessions: store.latestSessionListItems
    )

    Task { [weak self] in
      guard let self else { return }
      let changed = await self.sessionRegistry.apply(event)
      guard changed else { return }
      await self.scheduleSnapshotFlush()
    }
  }

  private func observeRootShellEvents(from runtime: ServerRuntime) {
    let store = runtime.sessionStore
    let endpointId = runtime.endpoint.id

    rootObservationTasks[endpointId] = Task { [weak self] in
      guard let self else { return }

      for await event in store.rootShellEvents {
        guard !Task.isCancelled else { break }

        let changed = await self.sessionRegistry.apply(event)
        guard changed else { continue }
        await self.scheduleSnapshotFlush()
      }
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
    let previousSessions = rootShellStore.records()
    let changed = rootShellStore.replace(with: snapshot.state)
    guard changed else { return }

    updatesContinuation.yield(
      RootShellRuntimeUpdate(
        previousSessions: previousSessions,
        currentSessions: snapshot.records
      )
    )
  }
}
