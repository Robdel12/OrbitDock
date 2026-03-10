import Testing
@testable import OrbitDock

@MainActor
struct OrbitDockAppRuntimeTests {
  @Test func liveDependenciesCreateFreshAppServices() {
    let dependencies = OrbitDockAppRuntimeDependencies.live(shouldConnectServer: false)
    let otherDependencies = OrbitDockAppRuntimeDependencies.live(shouldConnectServer: false)

    #expect(dependencies.runtimeRegistry !== otherDependencies.runtimeRegistry)
    #expect(dependencies.externalNavigationCenter !== otherDependencies.externalNavigationCenter)
    #expect(dependencies.notificationManager !== otherDependencies.notificationManager)
    #if os(macOS)
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
      shouldRequestAuthorizationOnStart: false
    )

    #if os(macOS)
      let serverManager = ServerManager(previewInstallState: .unknown)
      let runtime = OrbitDockAppRuntime(
        dependencies: OrbitDockAppRuntimeDependencies(
          runtimeRegistry: runtimeRegistry,
          externalNavigationCenter: externalNavigationCenter,
          notificationManager: notificationManager,
          appLifecycleClient: .disabled(),
          handleMemoryPressure: {},
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
          appLifecycleClient: .disabled(),
          handleMemoryPressure: {},
          shouldConnectServer: false
        )
      )

      #expect(runtime.runtimeRegistry === runtimeRegistry)
      #expect(runtime.externalNavigationCenter === externalNavigationCenter)
      #expect(runtime.notificationManager === notificationManager)
    #endif
  }

  @Test func startIfNeededRoutesMemoryWarningsThroughInjectedLifecycleClient() async {
    let runtimeRegistry = ServerRuntimeRegistry(
      endpointsProvider: { [] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    let externalNavigationCenter = AppExternalNavigationCenter()
    let notificationManager = NotificationManager(
      isAuthorized: false,
      shouldRequestAuthorizationOnStart: false
    )
    var memoryWarningContinuation: AsyncStream<Void>.Continuation?
    let memoryWarningStream = AsyncStream<Void> { continuation in
      memoryWarningContinuation = continuation
    }
    var observerStarted = false
    var observerStartedContinuation: CheckedContinuation<Void, Never>?
    let appLifecycleClient = AppLifecycleClient(
      memoryWarnings: {
        if !observerStarted {
          observerStarted = true
          observerStartedContinuation?.resume()
          observerStartedContinuation = nil
        }
        return memoryWarningStream
      }
    )
    var memoryPressureCount = 0
    var memoryPressureContinuation: CheckedContinuation<Void, Never>?

    #if os(macOS)
      let runtime = OrbitDockAppRuntime(
        dependencies: OrbitDockAppRuntimeDependencies(
          runtimeRegistry: runtimeRegistry,
          externalNavigationCenter: externalNavigationCenter,
          notificationManager: notificationManager,
          appLifecycleClient: appLifecycleClient,
          handleMemoryPressure: {
            memoryPressureCount += 1
            memoryPressureContinuation?.resume()
            memoryPressureContinuation = nil
          },
          shouldConnectServer: false,
          serverManager: ServerManager(previewInstallState: .unknown)
        )
      )
    #else
      let runtime = OrbitDockAppRuntime(
        dependencies: OrbitDockAppRuntimeDependencies(
          runtimeRegistry: runtimeRegistry,
          externalNavigationCenter: externalNavigationCenter,
          notificationManager: notificationManager,
          appLifecycleClient: appLifecycleClient,
          handleMemoryPressure: {
            memoryPressureCount += 1
            memoryPressureContinuation?.resume()
            memoryPressureContinuation = nil
          },
          shouldConnectServer: false
        )
      )
    #endif

    await runtime.startIfNeeded()
    if !observerStarted {
      await withCheckedContinuation { continuation in
        observerStartedContinuation = continuation
      }
    }
    memoryWarningContinuation?.yield(())
    if memoryPressureCount == 0 {
      await withCheckedContinuation { continuation in
        memoryPressureContinuation = continuation
      }
    }

    #expect(memoryPressureCount == 1)

    runtime.stop()
  }
}
