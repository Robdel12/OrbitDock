import Foundation

@MainActor
enum ServerRuntimeRegistryPlanner {
  static func preferredActiveEndpointID(from endpoints: [ServerEndpoint]) -> UUID? {
    endpoints.first(where: { $0.isDefault && $0.isEnabled })?.id
      ?? endpoints.first(where: \.isEnabled)?.id
      ?? endpoints.first?.id
  }

  static func resolvedActiveEndpointID(
    currentActiveEndpointId: UUID?,
    configuredEndpoints: [ServerEndpoint]
  ) -> UUID? {
    if let currentActiveEndpointId,
       configuredEndpoints.contains(where: { $0.id == currentActiveEndpointId && $0.isEnabled })
    {
      return currentActiveEndpointId
    }

    return preferredActiveEndpointID(from: configuredEndpoints)
  }

  static func displayConnectionStatus(
    connectionStatus: ConnectionStatus,
    readiness: ServerRuntimeReadiness
  ) -> ConnectionStatus {
    switch connectionStatus {
      case .connected where !readiness.queryReady:
        .connecting
      default:
        connectionStatus
    }
  }

  static func shouldBroadcastRuntimeStateChange(
    previousStatus: ConnectionStatus?,
    previousReadiness: ServerRuntimeReadiness,
    nextStatus: ConnectionStatus,
    nextReadiness: ServerRuntimeReadiness
  ) -> Bool {
    previousStatus != nextStatus || previousReadiness != nextReadiness
  }

  static func controlPlanePorts(
    runtimes: [ServerRuntime],
    readinessByEndpointId: [UUID: ServerRuntimeReadiness],
    requireControlPlaneReady: Bool
  ) -> [ServerControlPlanePort] {
    runtimes
      .filter(\.endpoint.isEnabled)
      .filter { runtime in
        !requireControlPlaneReady || readinessByEndpointId[runtime.endpoint.id]?.controlPlaneReady == true
      }
      .sorted { $0.endpoint.id.uuidString < $1.endpoint.id.uuidString }
      .map(\.controlPlanePort)
  }
}
