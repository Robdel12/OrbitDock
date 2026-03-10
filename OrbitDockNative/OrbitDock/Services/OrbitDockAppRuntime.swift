import Foundation

@Observable
@MainActor
final class OrbitDockAppRuntime {
  let runtimeRegistry: ServerRuntimeRegistry
  let externalNavigationCenter: AppExternalNavigationCenter
  let usageServiceRegistry: UsageServiceRegistry
  let startupCoordinator: ClientStartupCoordinator

  init(
    runtimeRegistry: ServerRuntimeRegistry,
    externalNavigationCenter: AppExternalNavigationCenter,
    shouldConnectServer: Bool
  ) {
    self.runtimeRegistry = runtimeRegistry
    self.externalNavigationCenter = externalNavigationCenter
    self.usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
    self.startupCoordinator = ClientStartupCoordinator(
      runtimeRegistry: runtimeRegistry,
      usageServiceRegistry: usageServiceRegistry,
      shouldConnectServer: shouldConnectServer
    )
  }

  convenience init() {
    self.init(
      runtimeRegistry: .shared,
      externalNavigationCenter: .shared,
      shouldConnectServer: AppRuntimeMode.current.shouldConnectServer
    )
  }

  func startIfNeeded() async {
    await startupCoordinator.startIfNeeded()
  }

  func refreshInstallAndConnectivity() async {
    await startupCoordinator.refreshInstallAndConnectivity()
  }

  func stop() {
    startupCoordinator.stop()
  }
}
