import Foundation
import Observation

@MainActor
final class EndpointListenerHub {
  private struct ListenerBinding {
    let connection: ServerConnection
    let token: ServerConnectionListenerToken
  }

  @ObservationIgnored private var bindingsByEndpointId: [UUID: ListenerBinding] = [:]

  func reconcile(
    runtimes: [ServerRuntime],
    onConnect: (_ endpointId: UUID, _ connection: ServerConnection) -> Void,
    onDisconnect: (_ endpointId: UUID, _ connection: ServerConnection) -> Void,
    makeListener: (_ endpointId: UUID, _ connection: ServerConnection) -> ((ServerEvent) -> Void)
  ) -> Bool {
    let activeConnectionsByEndpointId = Dictionary(
      uniqueKeysWithValues: runtimes.map { ($0.endpoint.id, $0.connection) }
    )
    var topologyChanged = false

    for (endpointId, binding) in Array(bindingsByEndpointId) {
      guard let activeConnection = activeConnectionsByEndpointId[endpointId],
            activeConnection === binding.connection
      else {
        onDisconnect(endpointId, binding.connection)
        binding.connection.removeListener(binding.token)
        bindingsByEndpointId.removeValue(forKey: endpointId)
        topologyChanged = true
        continue
      }
    }

    for runtime in runtimes {
      let endpointId = runtime.endpoint.id
      let connection = runtime.connection
      guard bindingsByEndpointId[endpointId] == nil else { continue }

      onConnect(endpointId, connection)
      let token = connection.addListener(makeListener(endpointId, connection))
      bindingsByEndpointId[endpointId] = ListenerBinding(connection: connection, token: token)
      topologyChanged = true
    }

    return topologyChanged
  }

  func clear(onDisconnect: (_ endpointId: UUID, _ connection: ServerConnection) -> Void) {
    for (endpointId, binding) in bindingsByEndpointId {
      onDisconnect(endpointId, binding.connection)
      binding.connection.removeListener(binding.token)
    }
    bindingsByEndpointId.removeAll()
  }
}

@MainActor
final class RuntimeTopologyObserver {
  @ObservationIgnored private var task: Task<Void, Never>?

  func start(
    runtimeRegistry: ServerRuntimeRegistry,
    onTopologyChanged: @escaping @MainActor () -> Void
  ) {
    stop()
    task = Task { @MainActor in
      for await _ in runtimeRegistry.readinessUpdates {
        guard !Task.isCancelled else { return }
        onTopologyChanged()
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }
}

@MainActor
final class CoalescedRefreshRunner {
  private struct ScheduledRefreshTask {
    let id: UInt64
    let task: Task<Void, Never>
  }

  @ObservationIgnored private var refreshTask: ScheduledRefreshTask?
  @ObservationIgnored private var refreshQueued = false
  @ObservationIgnored private var nextTaskID: UInt64 = 0

  func schedule(_ refresh: @escaping @MainActor () async -> Void) {
    refreshQueued = true
    guard refreshTask == nil else { return }
    nextTaskID += 1
    let taskID = nextTaskID
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      while self.refreshQueued {
        guard !Task.isCancelled else { break }
        self.refreshQueued = false
        await refresh()
      }
      if self.refreshTask?.id == taskID {
        self.refreshTask = nil
      }
    }
    refreshTask = ScheduledRefreshTask(id: taskID, task: task)
  }

  func waitForCurrentRefresh() async {
    let task = refreshTask?.task
    await task?.value
  }

  func cancel() {
    let task = refreshTask?.task
    refreshTask = nil
    refreshQueued = false
    task?.cancel()
  }
}
