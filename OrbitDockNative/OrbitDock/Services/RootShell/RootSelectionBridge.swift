import Foundation

@MainActor
final class RootSelectionBridge {
  private let runtimeRegistry: ServerRuntimeRegistry
  private let router: AppRouter
  private var selectionObservationTasks: [UUID: Task<Void, Never>] = [:]

  init(runtimeRegistry: ServerRuntimeRegistry, router: AppRouter) {
    self.runtimeRegistry = runtimeRegistry
    self.router = router
  }

  func start() {
    runtimeGraphDidChange()
  }

  func runtimeGraphDidChange() {
    let currentEndpointIDs = Set(runtimeRegistry.runtimes.map(\.endpoint.id))

    for endpointId in selectionObservationTasks.keys where !currentEndpointIDs.contains(endpointId) {
      selectionObservationTasks[endpointId]?.cancel()
      selectionObservationTasks.removeValue(forKey: endpointId)
    }

    for runtime in runtimeRegistry.runtimes where selectionObservationTasks[runtime.endpoint.id] == nil {
      let store = runtime.sessionStore
      let endpointId = runtime.endpoint.id
      let bridge = self
      selectionObservationTasks[endpointId] = Task {
        await bridge.observeSelectionRequests(from: store)
      }
    }
  }

  private func observeSelectionRequests(from store: SessionStore) async {
    for await ref in store.selectionRequests {
      guard !Task.isCancelled else { break }
      router.selectSession(ref)
    }
  }

  deinit {
    for task in selectionObservationTasks.values {
      task.cancel()
    }
  }
}
