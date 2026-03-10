import Foundation

struct UsageControlPlaneContext {
  let endpointId: UUID
  let usageClient: UsageClient
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
          usageClient: runtime.clients.usage,
          readiness: runtime.readiness
        )
      },
      primaryEndpointUpdates: runtimeRegistry.primaryEndpointUpdates
    )
  }
}
