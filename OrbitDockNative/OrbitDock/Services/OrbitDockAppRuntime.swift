import Foundation
import SwiftUI

#if os(macOS)
  private struct ServerManagerEnvironmentKey: EnvironmentKey {
    static let defaultValue = ServerManager.shared
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
  init(
    runtimeRegistry: ServerRuntimeRegistry,
    externalNavigationCenter: AppExternalNavigationCenter,
    notificationManager: NotificationManager,
    shouldConnectServer: Bool,
    serverManager: ServerManager
  ) {
    self.runtimeRegistry = runtimeRegistry
    self.externalNavigationCenter = externalNavigationCenter
    self.notificationManager = notificationManager
    self.usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
    self.serverManager = serverManager
    self.startupCoordinator = ClientStartupCoordinator(
      runtimeRegistry: runtimeRegistry,
      usageServiceRegistry: usageServiceRegistry,
      shouldConnectServer: shouldConnectServer,
      refreshInstallState: {
        await serverManager.refreshState()
        return serverManager.installState
      }
    )
  }

  convenience init() {
    self.init(
      runtimeRegistry: .shared,
      externalNavigationCenter: .shared,
      notificationManager: .shared,
      shouldConnectServer: AppRuntimeMode.current.shouldConnectServer,
      serverManager: .shared
    )
  }
  #else
    init(
      runtimeRegistry: ServerRuntimeRegistry,
      externalNavigationCenter: AppExternalNavigationCenter,
      notificationManager: NotificationManager,
      shouldConnectServer: Bool
    ) {
      self.runtimeRegistry = runtimeRegistry
      self.externalNavigationCenter = externalNavigationCenter
      self.notificationManager = notificationManager
      self.usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
      self.startupCoordinator = ClientStartupCoordinator(
        runtimeRegistry: runtimeRegistry,
        usageServiceRegistry: usageServiceRegistry,
        shouldConnectServer: shouldConnectServer,
        refreshInstallState: { .remote }
      )
    }

    convenience init() {
      self.init(
        runtimeRegistry: .shared,
        externalNavigationCenter: .shared,
        notificationManager: .shared,
        shouldConnectServer: AppRuntimeMode.current.shouldConnectServer
      )
    }
  #endif

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
