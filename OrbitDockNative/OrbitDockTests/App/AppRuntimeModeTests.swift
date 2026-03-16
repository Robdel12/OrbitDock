import Foundation
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

  @MainActor
  @Test func currentUsesInjectedEndpointSettingsForRemoteDetection() {
    let endpointSettings = ServerEndpointSettingsClient(
      endpoints: { [] },
      defaultEndpoint: {
        ServerEndpoint.localDefault()
      },
      hasRemoteEndpoint: { true },
      saveEndpoints: { _ in },
      buildURL: { _ in nil },
      hostInput: { _ in nil },
      defaultPort: 4_000
    )

    let mode = AppRuntimeMode.current(
      environment: [:],
      endpointSettings: endpointSettings,
      isRunningTests: false,
      platform: .iOS
    )

    #expect(mode == .remote)
  }
}
