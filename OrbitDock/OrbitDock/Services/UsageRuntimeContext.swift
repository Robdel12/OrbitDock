import Foundation

struct UsageRuntimeContext {
  let controlPlaneContext: @MainActor () -> (endpointId: UUID, apiClient: APIClient)?
  let primaryEndpointUpdates: AsyncStream<UUID?>

  static func live(runtimeRegistry: ServerRuntimeRegistry) -> UsageRuntimeContext {
    UsageRuntimeContext(
      controlPlaneContext: {
        guard let runtime = runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime else {
          return nil
        }
        return (runtime.endpoint.id, runtime.apiClient)
      },
      primaryEndpointUpdates: runtimeRegistry.primaryEndpointUpdates
    )
  }
}
