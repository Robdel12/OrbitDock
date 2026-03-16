import Foundation
@testable import OrbitDock
import Testing

struct CodexAccountRefreshPolicyTests {
  @Test func autoRefreshIsDisabledWhenRunningTests() {
    let environment = [
      "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration",
    ]

    #expect(SessionStore.shouldAutoRefreshCodexAccount(environment: environment) == false)
  }

  @Test func autoRefreshIsDisabledForDedicatedOrbitDockTestDatabaseRuns() {
    let environment = [
      "ORBITDOCK_TEST_DB": "/tmp/orbitdock-test.sqlite",
    ]

    #expect(SessionStore.shouldAutoRefreshCodexAccount(environment: environment) == false)
  }

  @Test func autoRefreshRemainsEnabledForNormalAppRuns() {
    #expect(SessionStore.shouldAutoRefreshCodexAccount(environment: [:]) == true)
  }
}
