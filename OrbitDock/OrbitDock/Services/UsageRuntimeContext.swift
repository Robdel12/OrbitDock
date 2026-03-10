import Foundation

struct UsageControlPlaneContext {
  let endpointId: UUID
  let apiClient: APIClient
  let readiness: ServerRuntimeReadiness

  var isReadyForRequests: Bool {
    readiness.queryReady
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
          readiness: runtime.readiness
        )
      },
      primaryEndpointUpdates: runtimeRegistry.primaryEndpointUpdates
    )
  }
}
