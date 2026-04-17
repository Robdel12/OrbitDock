import Foundation
import SwiftUI

@Observable
@MainActor
final class OrbitDockAppRuntime {
  let runtimeRegistry: ServerRuntimeRegistry
  let sessionsSummaryDataService: SessionsSummaryDataService
  let externalNavigationCenter: AppExternalNavigationCenter
  let notificationCoordinator: NotificationCoordinator
  let focusTracker: AppFocusTracker
  let usageServiceRegistry: UsageServiceRegistry
  let startupCoordinator: ClientStartupCoordinator
  let demoExperience: DemoModeExperience
  var isDemoModeEnabled = false
  var requestedSettingsPane: SettingsPane = .workspace
  @ObservationIgnored private var hasStarted = false

  convenience init() {
    let runtimeRegistry = Self.makeDefaultRuntimeRegistry()
    let shouldConnectServer = AppRuntimeMode.current.shouldConnectServer
    let sessionsSummaryDataService = SessionsSummaryDataService()
    let externalNavigationCenter = AppExternalNavigationCenter()
    let notificationCoordinator = NotificationCoordinator()
    let focusTracker = AppFocusTracker()
    let usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
    let startupCoordinator = ClientStartupCoordinator(
      runtimeRegistry: runtimeRegistry,
      shouldConnectServer: shouldConnectServer
    )

    self.init(
      runtimeRegistry: runtimeRegistry,
      sessionsSummaryDataService: sessionsSummaryDataService,
      externalNavigationCenter: externalNavigationCenter,
      notificationCoordinator: notificationCoordinator,
      focusTracker: focusTracker,
      usageServiceRegistry: usageServiceRegistry,
      startupCoordinator: startupCoordinator,
      demoExperience: DemoModeExperience()
    )
  }

  init(
    runtimeRegistry: ServerRuntimeRegistry,
    sessionsSummaryDataService: SessionsSummaryDataService,
    externalNavigationCenter: AppExternalNavigationCenter,
    notificationCoordinator: NotificationCoordinator,
    focusTracker: AppFocusTracker,
    usageServiceRegistry: UsageServiceRegistry,
    startupCoordinator: ClientStartupCoordinator,
    demoExperience: DemoModeExperience
  ) {
    self.runtimeRegistry = runtimeRegistry
    self.sessionsSummaryDataService = sessionsSummaryDataService
    self.externalNavigationCenter = externalNavigationCenter
    self.notificationCoordinator = notificationCoordinator
    self.focusTracker = focusTracker
    self.usageServiceRegistry = usageServiceRegistry
    self.startupCoordinator = startupCoordinator
    self.demoExperience = demoExperience
  }

  func startIfNeeded() async {
    guard !AppRuntimeMode.isRunningTestsProcess else { return }
    guard !hasStarted else { return }
    hasStarted = true
    notificationCoordinator.startIfNeeded()
    focusTracker.startObserving()
    await startupCoordinator.startIfNeeded()
    sessionsSummaryDataService.start(runtimeRegistry: runtimeRegistry)
  }

  func enterDemoMode() {
    // Fake a connected status for the demo endpoint so the composer
    // doesn't show "Offline" / "Server disconnected" banners.
    runtimeRegistry.injectDemoConnectionStatus(for: demoExperience.endpoint.id)

    isDemoModeEnabled = true
  }

  func exitDemoMode() {
    runtimeRegistry.clearDemoConnectionStatus(for: demoExperience.endpoint.id)
    isDemoModeEnabled = false
    sessionsSummaryDataService.applyDemoSessions([])
    Task {
      await sessionsSummaryDataService.refreshNow()
    }
  }

  private static func makeDefaultRuntimeRegistry() -> ServerRuntimeRegistry {
    guard !AppRuntimeMode.isRunningTestsProcess else {
      return ServerRuntimeRegistry(
        endpointsProvider: { [] },
        runtimeFactory: { _ in
          fatalError("OrbitDockAppRuntime test registry should never construct a live runtime")
        },
        shouldBootstrapFromSettings: false
      )
    }

    return ServerRuntimeRegistry()
  }
}
