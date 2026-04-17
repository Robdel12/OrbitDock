import Foundation
@testable import OrbitDock
import Testing

@Suite(.serialized)
@MainActor
struct AppStartupTests {
  @Test func orbitDockAppRuntimeStartupIsInertUnderTests() async {
    let runtimeRegistry = makeInertRuntimeRegistry()
    let appRuntime = OrbitDockAppRuntime(
      runtimeRegistry: runtimeRegistry,
      sessionsSummaryDataService: SessionsSummaryDataService(),
      externalNavigationCenter: AppExternalNavigationCenter(),
      notificationCoordinator: makeInertNotificationCoordinator(),
      focusTracker: AppFocusTracker(),
      usageServiceRegistry: UsageServiceRegistry(runtimeRegistry: runtimeRegistry),
      startupCoordinator: ClientStartupCoordinator(
        runtimeRegistry: runtimeRegistry,
        shouldConnectServer: false
      ),
      demoExperience: DemoModeExperience()
    )

    #expect(AppRuntimeMode.isRunningTestsProcess)

    await appRuntime.startIfNeeded()

    #expect(appRuntime.startupCoordinator.phase == .idle)
    #expect(appRuntime.runtimeRegistry.runtimes.isEmpty)
    #expect(appRuntime.sessionsSummaryDataService.activeSessions.isEmpty)
    #expect(appRuntime.sessionsSummaryDataService.recentSessions.isEmpty)
  }

  @Test func clientStartupCoordinatorBootstrapsAtMostOnce() async {
    var providerCalls = 0
    let runtimeRegistry = ServerRuntimeRegistry(
      endpointsProvider: {
        providerCalls += 1
        return []
      },
      runtimeFactory: { _ in
        fatalError("No runtime should be created for an empty endpoint list")
      },
      shouldBootstrapFromSettings: false
    )
    let coordinator = ClientStartupCoordinator(
      runtimeRegistry: runtimeRegistry,
      shouldConnectServer: true
    )

    await coordinator.startIfNeeded()
    await coordinator.startIfNeeded()

    #expect(coordinator.phase == .ready)
    #expect(providerCalls == 1)
  }

  @Test func clientStartupCoordinatorWaitsForSetupWhenConnectionIsDisabled() async {
    var providerCalls = 0
    let runtimeRegistry = ServerRuntimeRegistry(
      endpointsProvider: {
        providerCalls += 1
        return []
      },
      runtimeFactory: { _ in
        fatalError("Runtime construction should stay disabled when server startup is disabled")
      },
      shouldBootstrapFromSettings: false
    )
    let coordinator = ClientStartupCoordinator(
      runtimeRegistry: runtimeRegistry,
      shouldConnectServer: false
    )

    await coordinator.startIfNeeded()

    #expect(coordinator.phase == .waitingForSetup)
    #expect(providerCalls == 0)
  }

  private func makeInertRuntimeRegistry() -> ServerRuntimeRegistry {
    ServerRuntimeRegistry(
      endpointsProvider: { [] },
      runtimeFactory: { _ in
        fatalError("Test runtime should stay inert")
      },
      shouldBootstrapFromSettings: false
    )
  }

  private func makeInertNotificationCoordinator() -> NotificationCoordinator {
    NotificationCoordinator(
      notificationCenter: NotificationCenterClient(
        requestAuthorization: { completion in completion(true, nil) },
        setDelegate: { _ in },
        setNotificationCategories: { _ in },
        addRequest: { _, completion in completion(nil) },
        removeDeliveredNotifications: { _ in }
      ),
      preferences: NotificationPreferences(
        stringForKey: { _ in nil },
        objectForKey: { _ in nil },
        boolForKey: { _ in false }
      ),
      isRunningTestsProcess: true
    )
  }
}
