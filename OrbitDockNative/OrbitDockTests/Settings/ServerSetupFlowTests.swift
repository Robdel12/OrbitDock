@testable import OrbitDock
import Testing

@MainActor
struct ServerSetupVisibilityTests {
  @Test func showsSetupWhenNoEndpointsConfigured() {
    let shouldShow = AppWindowPlanner.shouldShowSetup(
      connectedRuntimeCount: 0,
      hasEndpoints: false
    )

    #expect(shouldShow)
  }

  @Test func hidesSetupWhenAnyRuntimeIsConnected() {
    let shouldShow = AppWindowPlanner.shouldShowSetup(
      connectedRuntimeCount: 1,
      hasEndpoints: true
    )

    #expect(!shouldShow)
  }

  @Test func hidesSetupWhenEndpointsExistButDisconnected() {
    let shouldShow = AppWindowPlanner.shouldShowSetup(
      connectedRuntimeCount: 0,
      hasEndpoints: true
    )

    #expect(!shouldShow)
  }
}
