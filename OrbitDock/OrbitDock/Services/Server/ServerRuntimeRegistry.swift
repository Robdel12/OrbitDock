import Foundation
import Combine

@Observable
@MainActor
final class ServerRuntimeRegistry {
  static let shared = ServerRuntimeRegistry()

  private let endpointsProvider: () -> [ServerEndpoint]
  private let runtimeFactory: (ServerEndpoint) -> ServerRuntime
  private(set) var runtimesByEndpointId: [UUID: ServerRuntime] = [:]
  private var statusSubscriptions: [UUID: AnyCancellable] = [:]
  private(set) var connectionStatusByEndpointId: [UUID: ConnectionStatus] = [:]
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
      if case .connected = connectionStatusByEndpointId[$0.endpoint.id] ?? $0.connection.status { return true }
      return false
    }.count
  }

  var activeConnectionStatus: ConnectionStatus {
    guard let activeEndpointId else { return .disconnected }
    return connectionStatusByEndpointId[activeEndpointId] ?? .disconnected
  }

  func configureFromSettings(startEnabled: Bool) {
    let configuredEndpoints = endpointsProvider()
    let configuredIds = Set(configuredEndpoints.map(\.id))

    for (id, runtime) in runtimesByEndpointId where !configuredIds.contains(id) {
      runtime.stop()
      runtimesByEndpointId[id] = nil
      statusSubscriptions[id]?.cancel()
      statusSubscriptions[id] = nil
      connectionStatusByEndpointId[id] = nil
    }

    for endpoint in configuredEndpoints {
      if let existing = runtimesByEndpointId[endpoint.id] {
        if existing.endpoint != endpoint {
          existing.stop()
          statusSubscriptions[endpoint.id]?.cancel()
          statusSubscriptions[endpoint.id] = nil
          let replacement = runtimeFactory(endpoint)
          runtimesByEndpointId[endpoint.id] = replacement
          observeConnectionStatus(for: replacement)
        }
      } else {
        let runtime = runtimeFactory(endpoint)
        runtimesByEndpointId[endpoint.id] = runtime
        observeConnectionStatus(for: runtime)
      }
    }

    activeEndpointId = Self.preferredActiveEndpointID(from: configuredEndpoints)

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

  func appState(for session: Session, fallback: ServerAppState) -> ServerAppState {
    guard let endpointId = session.endpointId,
          let runtime = runtimesByEndpointId[endpointId]
    else {
      return fallback
    }
    return runtime.appState
  }

  func sessionObservable(for session: Session, fallback: ServerAppState) -> SessionObservable {
    appState(for: session, fallback: fallback).session(session.id)
  }

  func isForkedSession(_ session: Session, fallback: ServerAppState) -> Bool {
    sessionObservable(for: session, fallback: fallback).forkedFrom != nil
  }

  func appState(for endpointId: UUID?, fallback: ServerAppState) -> ServerAppState {
    guard let endpointId,
          let runtime = runtimesByEndpointId[endpointId]
    else {
      return fallback
    }
    return runtime.appState
  }

  func connection(for endpointId: UUID?) -> ServerConnection? {
    guard let endpointId else { return nil }
    return runtimesByEndpointId[endpointId]?.connection
  }

  private func ensureInitialized() {
    if runtimesByEndpointId.isEmpty {
      configureFromSettings(startEnabled: false)
    }

    if runtimesByEndpointId.isEmpty {
      let endpoint = ServerEndpoint.localDefault(defaultPort: ServerEndpointSettings.defaultPort)
      let runtime = runtimeFactory(endpoint)
      runtimesByEndpointId[endpoint.id] = runtime
      observeConnectionStatus(for: runtime)
    }

    if activeEndpointId == nil {
      activeEndpointId = runtimesByEndpointId.keys.first
    }
  }

  private func observeConnectionStatus(for runtime: ServerRuntime) {
    let endpointId = runtime.endpoint.id
    connectionStatusByEndpointId[endpointId] = runtime.connection.status
    if statusSubscriptions[endpointId] != nil {
      return
    }

    statusSubscriptions[endpointId] = runtime.connection.$status.sink { [weak self] status in
      guard let self else { return }
      Task { @MainActor in
        self.connectionStatusByEndpointId[endpointId] = status
      }
    }
  }

  static func preferredActiveEndpointID(from endpoints: [ServerEndpoint]) -> UUID? {
    endpoints.first(where: { $0.isDefault && $0.isEnabled })?.id
      ?? endpoints.first(where: \.isEnabled)?.id
      ?? endpoints.first?.id
  }
}
