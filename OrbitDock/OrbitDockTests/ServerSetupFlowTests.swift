import Testing
@testable import OrbitDock

struct ServerSetupVisibilityTests {
  @Test func showsSetupWhenNotConfiguredAndNoConnectedRuntimes() {
    let shouldShow = ServerSetupVisibility.shouldShowSetup(
      connectedRuntimeCount: 0,
      installState: .notConfigured
    )

    #expect(shouldShow)
  }

  @Test func hidesSetupWhenAnyRuntimeIsConnected() {
    let shouldShow = ServerSetupVisibility.shouldShowSetup(
      connectedRuntimeCount: 1,
      installState: .notConfigured
    )

    #expect(!shouldShow)
  }

  @Test func hidesSetupWhenServerStateIsConfiguredButDisconnected() {
    let shouldShow = ServerSetupVisibility.shouldShowSetup(
      connectedRuntimeCount: 0,
      installState: .installed
    )

    #expect(!shouldShow)
  }
}

#if os(macOS)
  private func forcedStateLabel(_ state: ServerInstallState?) -> String {
    guard let state else { return "nil" }
    switch state {
      case .notConfigured: return "notConfigured"
      case .running: return "running"
      case .installed: return "installed"
      case .remote: return "remote"
      case .unknown: return "unknown"
    }
  }

  struct ServerManagerForcedStateParsingTests {
    @Test func parsesNotConfiguredAliases() {
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("not_configured")) == "notConfigured")
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("notconfigured")) == "notConfigured")
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("not-configured")) == "notConfigured")
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("  NOT_CONFIGURED  ")) == "notConfigured")
    }

    @Test func parsesKnownStates() {
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("running")) == "running")
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("installed")) == "installed")
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("remote")) == "remote")
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("unknown")) == "unknown")
    }

    @Test func returnsNilForInvalidInput() {
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState(nil)) == "nil")
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("")) == "nil")
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("   ")) == "nil")
      #expect(forcedStateLabel(ServerManager.parseForcedInstallState("garbage")) == "nil")
    }
  }
#endif
