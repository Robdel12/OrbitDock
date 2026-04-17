import Foundation
@testable import OrbitDock
import Testing

struct CodexAccountRefreshPolicyTests {
  @Test func autoRefreshIsDisabledWhenRunningTests() {
    let environment = [
      "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration",
    ]

    #expect(ServerEndpointRuntime.shouldAutoRefreshCodexAccount(environment: environment) == false)
  }

  @Test func autoRefreshIsDisabledForDedicatedOrbitDockTestDatabaseRuns() {
    let environment = [
      "ORBITDOCK_TEST_DB": "/tmp/orbitdock-test.sqlite",
    ]

    #expect(ServerEndpointRuntime.shouldAutoRefreshCodexAccount(environment: environment) == false)
  }

  @Test func autoRefreshRemainsEnabledForNormalAppRuns() {
    #expect(ServerEndpointRuntime.shouldAutoRefreshCodexAccount(environment: [:]) == true)
  }
}
