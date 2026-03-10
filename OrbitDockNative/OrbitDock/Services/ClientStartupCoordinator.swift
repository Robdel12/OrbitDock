import Foundation

enum ClientStartupPhase: Equatable {
  case idle
  case bootstrapping
  case waitingForSetup
  case waitingForRuntimeReady
  case ready
  case stopped
}

@Observable
@MainActor
final class ClientStartupCoordinator {
  private let runtimeRegistry: ServerRuntimeRegistry
  private let usageServiceRegistry: UsageServiceRegistry
  private let refreshInstallState: @MainActor () async -> ServerInstallState
  private let shouldConnectServer: Bool

  private(set) var phase: ClientStartupPhase = .idle
  private var hasBootstrapped = false

  init(
    runtimeRegistry: ServerRuntimeRegistry,
    usageServiceRegistry: UsageServiceRegistry,
    shouldConnectServer: Bool,
    refreshInstallState: @escaping @MainActor () async -> ServerInstallState
  ) {
    self.runtimeRegistry = runtimeRegistry
    self.usageServiceRegistry = usageServiceRegistry
    self.shouldConnectServer = shouldConnectServer
    self.refreshInstallState = refreshInstallState
  }

  func startIfNeeded() async {
    guard !hasBootstrapped else { return }
    hasBootstrapped = true
    await start()
  }

  func start() async {
    guard shouldConnectServer else {
      phase = .idle
      usageServiceRegistry.stop()
      return
    }

    phase = .bootstrapping
    runtimeRegistry.configureFromSettings(startEnabled: false)

    let installState = await refreshInstallState()
    guard UsageServiceRegistry.shouldStartServices(
      shouldConnectServer: shouldConnectServer,
      installState: installState
    ) else {
      usageServiceRegistry.stop()
      phase = .waitingForSetup
      return
    }

    runtimeRegistry.startEnabledRuntimes()
    phase = .waitingForRuntimeReady
    await runtimeRegistry.waitForAnyQueryReadyRuntime()

    guard runtimeRegistry.hasAnyQueryReadyRuntime else { return }

    usageServiceRegistry.start()
    phase = .ready
  }

  func refreshInstallAndConnectivity() async {
    guard shouldConnectServer else { return }
    let installState = await refreshInstallState()
    guard UsageServiceRegistry.shouldStartServices(
      shouldConnectServer: shouldConnectServer,
      installState: installState
    ) else {
      usageServiceRegistry.stop()
      phase = .waitingForSetup
      return
    }

    runtimeRegistry.startEnabledRuntimes()
    phase = .waitingForRuntimeReady
    await runtimeRegistry.waitForAnyQueryReadyRuntime()

    guard runtimeRegistry.hasAnyQueryReadyRuntime else { return }

    usageServiceRegistry.start()
    phase = .ready
  }

  func stop() {
    usageServiceRegistry.stop()
    runtimeRegistry.stopAllRuntimes()
    phase = .stopped
  }
}
