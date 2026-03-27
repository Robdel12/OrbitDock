import Foundation
@testable import OrbitDock
import Testing

struct ServerEndpointSelectionTests {
  @Test func initialEndpointIDPrefersContinuationEndpoint() throws {
    let endpoint = try ServerEndpoint(
      name: "Remote",
      wsURL: #require(URL(string: "ws://10.0.0.5:4000/ws")),
      isDefault: true
    )
    let continuationEndpointID = UUID()

    let selectedID = ServerEndpointSelection.initialEndpointID(
      continuationEndpointID: continuationEndpointID,
      availableEndpoints: [endpoint],
      fallbackDefaultEndpointID: endpoint.id
    )

    #expect(selectedID == continuationEndpointID)
  }

  @Test func initialEndpointIDFallsBackToInjectedEndpointsBeforeDefault() throws {
    let first = try ServerEndpoint(
      name: "First",
      wsURL: #require(URL(string: "ws://10.0.0.5:4000/ws")),
      isDefault: false
    )
    let preferred = try ServerEndpoint(
      name: "Preferred",
      wsURL: #require(URL(string: "ws://10.0.0.6:4000/ws")),
      isDefault: true
    )
    let fallbackDefaultID = UUID()

    let selectedID = ServerEndpointSelection.initialEndpointID(
      continuationEndpointID: nil,
      availableEndpoints: [first, preferred],
      fallbackDefaultEndpointID: fallbackDefaultID
    )

    #expect(selectedID == preferred.id)
  }

  @Test func resolvedEndpointIDFallsBackToPreferredConfiguredEndpoint() throws {
    let disabledDefault = try ServerEndpoint(
      name: "Disabled Default",
      wsURL: #require(URL(string: "ws://10.0.0.5:4000/ws")),
      isEnabled: false,
      isDefault: true
    )
    let enabled = try ServerEndpoint(
      name: "Enabled",
      wsURL: #require(URL(string: "ws://10.0.0.6:4000/ws")),
      isEnabled: true,
      isDefault: false
    )

    let selectedID = ServerEndpointSelection.resolvedEndpointID(
      explicitEndpointID: nil,
      primaryEndpointID: nil,
      activeEndpointID: nil,
      availableEndpoints: [disabledDefault, enabled]
    )

    #expect(selectedID == enabled.id)
  }
}
