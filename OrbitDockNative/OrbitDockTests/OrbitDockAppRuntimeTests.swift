import Testing
@testable import OrbitDock

@MainActor
struct OrbitDockAppRuntimeTests {
  @Test func liveDependenciesCreateFreshAppServices() {
    let dependencies = OrbitDockAppRuntimeDependencies.live(shouldConnectServer: false)
    let otherDependencies = OrbitDockAppRuntimeDependencies.live(shouldConnectServer: false)

    #expect(dependencies.runtimeRegistry !== ServerRuntimeRegistry.shared)
    #expect(dependencies.externalNavigationCenter !== otherDependencies.externalNavigationCenter)
    #expect(dependencies.notificationManager !== otherDependencies.notificationManager)
    #if os(macOS)
      #expect(dependencies.serverManager !== ServerManager.shared)
      #expect(dependencies.serverManager !== otherDependencies.serverManager)
    #endif
  }

  @Test func runtimeKeepsInjectedDependenciesAsTheCompositionRoot() {
    let runtimeRegistry = ServerRuntimeRegistry(
      endpointsProvider: { [] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    let externalNavigationCenter = AppExternalNavigationCenter()
    let notificationManager = NotificationManager(
      isAuthorized: false,
      requestsAuthorizationOnInit: false
    )

    #if os(macOS)
      let serverManager = ServerManager(previewInstallState: .unknown)
      let runtime = OrbitDockAppRuntime(
        dependencies: OrbitDockAppRuntimeDependencies(
          runtimeRegistry: runtimeRegistry,
          externalNavigationCenter: externalNavigationCenter,
          notificationManager: notificationManager,
          shouldConnectServer: false,
          serverManager: serverManager
        )
      )

      #expect(runtime.runtimeRegistry === runtimeRegistry)
      #expect(runtime.externalNavigationCenter === externalNavigationCenter)
      #expect(runtime.notificationManager === notificationManager)
      #expect(runtime.serverManager === serverManager)
    #else
      let runtime = OrbitDockAppRuntime(
        dependencies: OrbitDockAppRuntimeDependencies(
          runtimeRegistry: runtimeRegistry,
          externalNavigationCenter: externalNavigationCenter,
          notificationManager: notificationManager,
          shouldConnectServer: false
        )
      )

      #expect(runtime.runtimeRegistry === runtimeRegistry)
      #expect(runtime.externalNavigationCenter === externalNavigationCenter)
      #expect(runtime.notificationManager === notificationManager)
    #endif
  }
}
