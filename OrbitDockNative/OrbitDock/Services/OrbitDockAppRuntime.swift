import Foundation
import SwiftUI

#if os(macOS)
  private struct ServerManagerEnvironmentKey: EnvironmentKey {
    static let defaultValue = ServerManager.missingEnvironmentDefault()
  }

  extension EnvironmentValues {
    var serverManager: ServerManager {
      get { self[ServerManagerEnvironmentKey.self] }
      set { self[ServerManagerEnvironmentKey.self] = newValue }
    }
  }
#endif

@Observable
@MainActor
final class OrbitDockAppRuntime {
  let runtimeRegistry: ServerRuntimeRegistry
  let externalNavigationCenter: AppExternalNavigationCenter
  let notificationManager: NotificationManager
  let usageServiceRegistry: UsageServiceRegistry
  let startupCoordinator: ClientStartupCoordinator
  #if os(macOS)
    let serverManager: ServerManager
  #endif

  #if os(macOS)
    init() {
      let runtimeRegistry = ServerRuntimeRegistry()
      self.runtimeRegistry = runtimeRegistry
      self.externalNavigationCenter = AppExternalNavigationCenter()
      self.notificationManager = NotificationManager()
      self.usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
      self.serverManager = .live()
      self.startupCoordinator = ClientStartupCoordinator(
        runtimeRegistry: runtimeRegistry,
        shouldConnectServer: AppRuntimeMode.current.shouldConnectServer
      )
    }
  #else
    init() {
      let runtimeRegistry = ServerRuntimeRegistry()
      self.runtimeRegistry = runtimeRegistry
      self.externalNavigationCenter = AppExternalNavigationCenter()
      self.notificationManager = NotificationManager()
      self.usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
      self.startupCoordinator = ClientStartupCoordinator(
        runtimeRegistry: runtimeRegistry,
        shouldConnectServer: AppRuntimeMode.current.shouldConnectServer
      )
    }
  #endif

  func startIfNeeded() async {
    notificationManager.startIfNeeded()
    await startupCoordinator.startIfNeeded()
  }
}
