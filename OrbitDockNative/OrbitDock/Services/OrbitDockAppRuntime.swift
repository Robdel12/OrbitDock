import Foundation
import SwiftUI

@Observable
@MainActor
final class OrbitDockAppRuntime {
  let runtimeRegistry: ServerRuntimeRegistry
  let externalNavigationCenter: AppExternalNavigationCenter
  let notificationCoordinator: NotificationCoordinator
  let focusTracker: AppFocusTracker
  let usageServiceRegistry: UsageServiceRegistry
  let startupCoordinator: ClientStartupCoordinator
  let demoExperience: DemoModeExperience
  var isDemoModeEnabled = false

  init() {
    let runtimeRegistry = ServerRuntimeRegistry()
    self.runtimeRegistry = runtimeRegistry
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
  }

  func enterDemoMode() {
    // Push demo data into the projection store BEFORE setting the flag,
    // so the dashboard sees demo data immediately rather than waiting for
    // the SwiftUI onChange chain to propagate.
    let demo = demoExperience
    let snapshot = DashboardProjectionBuilder.build(
      rootSessions: demo.rootSessions,
      dashboardConversations: demo.dashboardConversations,
      refreshIdentity: "demo-\(UUID().uuidString.prefix(8))"
    )
    runtimeRegistry.dashboardProjectionStore.applyDemo(snapshot)

    // Fake a connected status for the demo endpoint so the composer
    // doesn't show "Offline" / "Server disconnected" banners.
    runtimeRegistry.injectDemoConnectionStatus(for: demo.endpoint.id)

    isDemoModeEnabled = true
  }

  func exitDemoMode() {
    runtimeRegistry.clearDemoConnectionStatus(for: demoExperience.endpoint.id)
    runtimeRegistry.dashboardProjectionStore.clearDemoOverride()
    isDemoModeEnabled = false
    // Trigger a real data refresh so the dashboard repopulates
    Task {
      await runtimeRegistry.refreshDashboardConversations()
    }
  }
}
