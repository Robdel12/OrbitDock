@testable import OrbitDock
import Testing

@MainActor
struct ClientStartupCoordinatorTests {
  @Test func startIfNeededUsesInjectedInstallStateRefreshWhenServerConnectionIsEnabled() async {
    let runtimeRegistry = ServerRuntimeRegistry(
      endpointsProvider: { [] },
      runtimeFactory: { _ in
        Issue.record("runtimeFactory should not run for an empty endpoint list")
        return ServerRuntime(endpoint: ServerEndpointSettings.defaultEndpoint)
      },
      shouldBootstrapFromSettings: false
    )
    let usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
    var refreshCount = 0

    let coordinator = ClientStartupCoordinator(
      runtimeRegistry: runtimeRegistry,
      usageServiceRegistry: usageServiceRegistry,
      shouldConnectServer: true,
      refreshInstallState: {
        refreshCount += 1
        return .notConfigured
      }
    )

    await coordinator.startIfNeeded()

    #expect(refreshCount == 1)
    #expect(coordinator.phase == .waitingForSetup)
  }

  @Test func startIfNeededSkipsInstallRefreshWhenServerConnectionIsDisabled() async {
    let runtimeRegistry = ServerRuntimeRegistry(
      endpointsProvider: { [] },
      runtimeFactory: { _ in
        Issue.record("runtimeFactory should not run when server connectivity is disabled")
        return ServerRuntime(endpoint: ServerEndpointSettings.defaultEndpoint)
      },
      shouldBootstrapFromSettings: false
    )
    let usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
    var refreshCount = 0

    let coordinator = ClientStartupCoordinator(
      runtimeRegistry: runtimeRegistry,
      usageServiceRegistry: usageServiceRegistry,
      shouldConnectServer: false,
      refreshInstallState: {
        refreshCount += 1
        return .running
      }
    )

    await coordinator.startIfNeeded()

    #expect(refreshCount == 0)
    #expect(coordinator.phase == .idle)
  }
}
