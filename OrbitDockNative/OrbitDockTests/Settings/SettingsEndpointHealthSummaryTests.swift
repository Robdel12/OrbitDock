import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SettingsEndpointHealthSummaryTests {
  @Test func connectedEnabledEndpointCountIgnoresDisabledConnectedEndpoints() {
    let enabledEndpoint = ServerEndpoint(
      id: UUID(),
      name: "Enabled",
      wsURL: URL(string: "ws://enabled.example")!,
      isEnabled: true,
      isDefault: true,
      authToken: "tok_enabled"
    )
    let disabledEndpoint = ServerEndpoint(
      id: UUID(),
      name: "Disabled",
      wsURL: URL(string: "ws://disabled.example")!,
      isEnabled: false,
      isDefault: false,
      authToken: "tok_disabled"
    )
    let runtimes = [ServerRuntime(endpoint: enabledEndpoint), ServerRuntime(endpoint: disabledEndpoint)]

    let connectedCount = SettingsEndpointHealthSummary.connectedEnabledEndpointCount(for: runtimes) {
      $0 == enabledEndpoint.id ? .disconnected : .connected
    }

    #expect(connectedCount == 0)
  }

  @Test func noEnabledEndpointsUsesWarningCopy() {
    let summary = SettingsEndpointHealthSummary.make(
      endpointCount: 2,
      enabledEndpointCount: 0,
      connectedEndpointCount: 0
    )

    #expect(summary.tone == .warning)
    #expect(summary.shortText == "No enabled endpoints")
    #expect(summary.detailedText == "No enabled endpoints")
    #expect(summary.endpointCount == 2)
  }

  @Test func fullyConnectedEndpointsUsePositiveCopy() {
    let summary = SettingsEndpointHealthSummary.make(
      endpointCount: 3,
      enabledEndpointCount: 2,
      connectedEndpointCount: 2
    )

    #expect(summary.tone == .positive)
    #expect(summary.shortText == "2/2 connected")
    #expect(summary.detailedText == "2 of 2 enabled connected")
  }

  @Test func partiallyConnectedEndpointsUseMixedCopy() {
    let summary = SettingsEndpointHealthSummary.make(
      endpointCount: 4,
      enabledEndpointCount: 3,
      connectedEndpointCount: 1
    )

    #expect(summary.tone == .mixed)
    #expect(summary.shortText == "1/3 connected")
    #expect(summary.detailedText == "1 of 3 enabled connected")
  }

  @Test func disconnectedEnabledEndpointsUseWarningCopy() {
    let summary = SettingsEndpointHealthSummary.make(
      endpointCount: 1,
      enabledEndpointCount: 1,
      connectedEndpointCount: 0
    )

    #expect(summary.tone == .warning)
    #expect(summary.shortText == "0/1 connected")
    #expect(summary.detailedText == "0 of 1 enabled connected")
  }
}
