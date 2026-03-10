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

@MainActor
struct OrbitDockAppRuntimeDependencies {
  let runtimeRegistry: ServerRuntimeRegistry
  let externalNavigationCenter: AppExternalNavigationCenter
  let notificationManager: NotificationManager
  let shouldConnectServer: Bool
  #if os(macOS)
    let serverManager: ServerManager
  #endif

  #if os(macOS)
    static func live() -> OrbitDockAppRuntimeDependencies {
      live(shouldConnectServer: AppRuntimeMode.current.shouldConnectServer)
    }

    static func live(
      shouldConnectServer: Bool
    ) -> OrbitDockAppRuntimeDependencies {
      OrbitDockAppRuntimeDependencies(
        runtimeRegistry: ServerRuntimeRegistry(),
        externalNavigationCenter: AppExternalNavigationCenter(),
        notificationManager: NotificationManager(),
        shouldConnectServer: shouldConnectServer,
        serverManager: .shared
      )
    }
  #else
    static func live() -> OrbitDockAppRuntimeDependencies {
      live(shouldConnectServer: AppRuntimeMode.current.shouldConnectServer)
    }

    static func live(
      shouldConnectServer: Bool
    ) -> OrbitDockAppRuntimeDependencies {
      OrbitDockAppRuntimeDependencies(
        runtimeRegistry: ServerRuntimeRegistry(),
        externalNavigationCenter: AppExternalNavigationCenter(),
        notificationManager: NotificationManager(),
        shouldConnectServer: shouldConnectServer
      )
    }
  #endif
}

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
  init(dependencies: OrbitDockAppRuntimeDependencies) {
    self.runtimeRegistry = dependencies.runtimeRegistry
    self.externalNavigationCenter = dependencies.externalNavigationCenter
    self.notificationManager = dependencies.notificationManager
    self.usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
    self.serverManager = dependencies.serverManager
    self.startupCoordinator = ClientStartupCoordinator(
      runtimeRegistry: runtimeRegistry,
      usageServiceRegistry: usageServiceRegistry,
      shouldConnectServer: dependencies.shouldConnectServer,
      refreshInstallState: {
        await dependencies.serverManager.refreshState()
        return dependencies.serverManager.installState
      }
    )
  }

  static func live(
  ) -> OrbitDockAppRuntime {
    OrbitDockAppRuntime(
      dependencies: OrbitDockAppRuntimeDependencies.live()
    )
  }

  static func live(
    shouldConnectServer: Bool
  ) -> OrbitDockAppRuntime {
    OrbitDockAppRuntime(
      dependencies: OrbitDockAppRuntimeDependencies.live(
        shouldConnectServer: shouldConnectServer
      )
    )
  }
  #else
    init(dependencies: OrbitDockAppRuntimeDependencies) {
      self.runtimeRegistry = dependencies.runtimeRegistry
      self.externalNavigationCenter = dependencies.externalNavigationCenter
      self.notificationManager = dependencies.notificationManager
      self.usageServiceRegistry = UsageServiceRegistry(runtimeRegistry: runtimeRegistry)
      self.startupCoordinator = ClientStartupCoordinator(
        runtimeRegistry: runtimeRegistry,
        usageServiceRegistry: usageServiceRegistry,
        shouldConnectServer: dependencies.shouldConnectServer,
        refreshInstallState: { .remote }
      )
    }

    static func live(
    ) -> OrbitDockAppRuntime {
      OrbitDockAppRuntime(
        dependencies: OrbitDockAppRuntimeDependencies.live()
      )
    }

    static func live(
      shouldConnectServer: Bool
    ) -> OrbitDockAppRuntime {
      OrbitDockAppRuntime(
        dependencies: OrbitDockAppRuntimeDependencies.live(
          shouldConnectServer: shouldConnectServer
        )
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
