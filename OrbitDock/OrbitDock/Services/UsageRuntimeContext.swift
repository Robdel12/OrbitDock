import Foundation

struct UsageControlPlaneContext {
  let endpointId: UUID
  let apiClient: APIClient
  let connectionStatus: ConnectionStatus

  var isReadyForRequests: Bool {
    connectionStatus == .connected
  }
}

struct UsageRuntimeContext {
  let controlPlaneContext: @MainActor () -> UsageControlPlaneContext?
  let primaryEndpointUpdates: AsyncStream<UUID?>

  static func live(runtimeRegistry: ServerRuntimeRegistry) -> UsageRuntimeContext {
    UsageRuntimeContext(
      controlPlaneContext: {
        guard let runtime = runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime else {
          return nil
        }
        return UsageControlPlaneContext(
          endpointId: runtime.endpoint.id,
          apiClient: runtime.apiClient,
          connectionStatus: runtime.eventStream.connectionStatus
        )
      },
      primaryEndpointUpdates: runtimeRegistry.primaryEndpointUpdates
    )
  }
}
