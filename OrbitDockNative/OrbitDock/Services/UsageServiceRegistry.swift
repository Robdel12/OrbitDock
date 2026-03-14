import Foundation

@Observable
@MainActor
final class UsageServiceRegistry {
  private let runtimeRegistry: ServerRuntimeRegistry

  init(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
  }

  var allProviders: [Provider] {
    [.claude, .codex]
  }

  var activeProviders: [Provider] {
    []
  }

  var isAnyLoading: Bool {
    false
  }

  func windows(for provider: Provider) -> [RateLimitWindow] {
    []
  }

  func error(for provider: Provider) -> (any LocalizedError)? {
    nil
  }

  func isLoading(for provider: Provider) -> Bool {
    false
  }

  func isStale(for provider: Provider) -> Bool {
    false
  }

  func planName(for provider: Provider) -> String? {
    nil
  }

  func refreshAll() async {
    // Stub: no-op
  }

  func start() {
    // Stub: no-op
  }

  func stop() {
    // Stub: no-op
  }

  nonisolated static func shouldStartServices(
    shouldConnectServer: Bool,
    installState: ServerInstallState
  ) -> Bool {
    guard shouldConnectServer else { return false }
    switch installState {
      case .running, .installed, .remote:
        return true
      case .unknown, .notConfigured:
        return false
    }
  }
}
