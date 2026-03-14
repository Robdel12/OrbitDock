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
  private let shouldConnectServer: Bool

  private(set) var phase: ClientStartupPhase = .idle
  private var hasBootstrapped = false

  init(
    runtimeRegistry: ServerRuntimeRegistry,
    shouldConnectServer: Bool
  ) {
    self.runtimeRegistry = runtimeRegistry
    self.shouldConnectServer = shouldConnectServer
  }

  func startIfNeeded() async {
    guard !hasBootstrapped else { return }
    hasBootstrapped = true
    phase = .bootstrapping

    guard shouldConnectServer else {
      phase = .waitingForSetup
      return
    }

    runtimeRegistry.configureFromSettings(startEnabled: true)
    runtimeRegistry.startEnabledRuntimes()
    phase = .ready
  }

  func refreshInstallAndConnectivity() async {
    runtimeRegistry.reconnectAllIfNeeded()
  }

  func stop() {
    phase = .stopped
    runtimeRegistry.stopAllRuntimes()
  }
}
