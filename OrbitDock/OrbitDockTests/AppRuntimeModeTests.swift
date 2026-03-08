@testable import OrbitDock
import Testing

struct AppRuntimeModeTests {
  @Test func macOSTestsDefaultToMock() {
    let mode = AppRuntimeMode.resolved(
      environment: [:],
      hasRemoteEndpoint: false,
      isRunningTests: true,
      platform: .macOS
    )

    #expect(mode == .mock)
  }

  @Test func explicitOverrideWinsDuringTests() {
    let mode = AppRuntimeMode.resolved(
      environment: [AppRuntimeMode.environmentKey: "live"],
      hasRemoteEndpoint: false,
      isRunningTests: true,
      platform: .macOS
    )

    #expect(mode == .live)
  }

  @Test func iOSUsesRemoteOutsideTestsWhenConfigured() {
    let mode = AppRuntimeMode.resolved(
      environment: [:],
      hasRemoteEndpoint: true,
      isRunningTests: false,
      platform: .iOS
    )

    #expect(mode == .remote)
  }
}
