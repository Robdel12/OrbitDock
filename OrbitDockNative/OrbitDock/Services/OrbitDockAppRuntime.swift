import Foundation
import SwiftUI

@Observable
@MainActor
final class OrbitDockAppRuntime {
  let runtimeRegistry: ServerRuntimeRegistry
  let dashboardDataService: DashboardDataService
  let externalNavigationCenter: AppExternalNavigationCenter
  let notificationCoordinator: NotificationCoordinator
  let focusTracker: AppFocusTracker
  let usageServiceRegistry: UsageServiceRegistry
  let startupCoordinator: ClientStartupCoordinator
  let demoExperience: DemoModeExperience
  var isDemoModeEnabled = false
  var requestedSettingsPane: SettingsPane = .workspace

  init() {
    let runtimeRegistry = ServerRuntimeRegistry()
    self.runtimeRegistry = runtimeRegistry
    self.dashboardDataService = DashboardDataService()
    self.externalNavigationCenter = AppExternalNavigationCenter()
    self.notificationCoordinator = NotificationCoordinator()
    self.focusTracker = AppFocusTracker()
    self.usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
    self.demoExperience = DemoModeExperience()
    self.startupCoordinator = ClientStartupCoordinator(
      runtimeRegistry: runtimeRegistry,
      shouldConnectServer: AppRuntimeMode.current.shouldConnectServer
    )
  }

  func startIfNeeded() async {
    notificationCoordinator.startIfNeeded()
    focusTracker.startObserving()
    await startupCoordinator.startIfNeeded()
    dashboardDataService.start(runtimeRegistry: runtimeRegistry)
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
    // Trigger a real data refresh so the dashboard repopulates
    Task {
      await runtimeRegistry.refreshDashboardConversations()
    }
  }
}
