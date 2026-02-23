import Foundation

@Observable
@MainActor
final class ServerRuntimeRegistry {
  static let shared = ServerRuntimeRegistry()

  private let endpointsProvider: () -> [ServerEndpoint]
  private let runtimeFactory: (ServerEndpoint) -> ServerRuntime
  private(set) var runtimesByEndpointId: [UUID: ServerRuntime] = [:]
  private(set) var activeEndpointId: UUID?

  init() {
    endpointsProvider = { ServerEndpointSettings.endpoints }
    runtimeFactory = { ServerRuntime(endpoint: $0) }
  }

  init(
    endpointsProvider: @escaping () -> [ServerEndpoint],
    runtimeFactory: @escaping (ServerEndpoint) -> ServerRuntime
  ) {
    self.endpointsProvider = endpointsProvider
    self.runtimeFactory = runtimeFactory
  }

  var runtimes: [ServerRuntime] {
    runtimesByEndpointId.values.sorted { $0.endpoint.name < $1.endpoint.name }
  }

  var activeRuntime: ServerRuntime? {
    guard let activeEndpointId else { return nil }
    return runtimesByEndpointId[activeEndpointId]
  }

  var activeConnection: ServerConnection {
    ensureInitialized()
    guard let activeEndpointId, let runtime = runtimesByEndpointId[activeEndpointId] else {
      fatalError("ServerRuntimeRegistry has no active runtime")
    }
    return runtime.connection
  }

  var activeAppState: ServerAppState {
    ensureInitialized()
    guard let activeEndpointId, let runtime = runtimesByEndpointId[activeEndpointId] else {
      fatalError("ServerRuntimeRegistry has no active runtime")
    }
    return runtime.appState
  }

  var connectedRuntimeCount: Int {
    runtimes.filter {
      if case .connected = $0.connection.status { return true }
      return false
    }.count
  }

  func configureFromSettings(startEnabled: Bool) {
    let configuredEndpoints = endpointsProvider()
    let configuredIds = Set(configuredEndpoints.map(\.id))

    for (id, runtime) in runtimesByEndpointId where !configuredIds.contains(id) {
      runtime.stop()
      runtimesByEndpointId[id] = nil
    }

    for endpoint in configuredEndpoints {
      if let existing = runtimesByEndpointId[endpoint.id] {
        if existing.endpoint != endpoint {
          existing.stop()
          let replacement = runtimeFactory(endpoint)
          runtimesByEndpointId[endpoint.id] = replacement
        }
      } else {
        runtimesByEndpointId[endpoint.id] = runtimeFactory(endpoint)
      }
    }

    if let activeEndpointId, runtimesByEndpointId[activeEndpointId] == nil {
      self.activeEndpointId = nil
    }

    if self.activeEndpointId == nil {
      self.activeEndpointId = configuredEndpoints.first(where: { $0.isDefault && $0.isEnabled })?.id
        ?? configuredEndpoints.first(where: \.isEnabled)?.id
        ?? configuredEndpoints.first?.id
    }

    guard startEnabled else { return }

    for endpoint in configuredEndpoints where endpoint.isEnabled {
      runtimesByEndpointId[endpoint.id]?.start()
    }
  }

  func setActiveEndpoint(id: UUID) {
    guard runtimesByEndpointId[id] != nil else { return }
    activeEndpointId = id
  }

  func reconnect(endpointId: UUID) {
    runtimesByEndpointId[endpointId]?.reconnect()
  }

  func stop(endpointId: UUID) {
    runtimesByEndpointId[endpointId]?.stop()
  }

  func startEnabledRuntimes() {
    configureFromSettings(startEnabled: true)
  }

  func stopAllRuntimes() {
    for runtime in runtimesByEndpointId.values {
      runtime.stop()
    }
  }

  private func ensureInitialized() {
    if runtimesByEndpointId.isEmpty {
      configureFromSettings(startEnabled: false)
    }

    if runtimesByEndpointId.isEmpty {
      let endpoint = ServerEndpoint.localDefault(defaultPort: ServerEndpointSettings.defaultPort)
      let runtime = runtimeFactory(endpoint)
      runtimesByEndpointId[endpoint.id] = runtime
    }

    if activeEndpointId == nil {
      activeEndpointId = runtimesByEndpointId.keys.first
    }
  }
}
