import Foundation
import Testing
@testable import OrbitDock

struct ServerEndpointSelectionTests {
  @Test func initialEndpointIDPrefersContinuationEndpoint() {
    let endpoint = ServerEndpoint(
      name: "Remote",
      wsURL: URL(string: "ws://10.0.0.5:4000/ws")!,
      isLocalManaged: false,
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

  @Test func initialEndpointIDFallsBackToInjectedEndpointsBeforeDefault() {
    let first = ServerEndpoint(
      name: "First",
      wsURL: URL(string: "ws://10.0.0.5:4000/ws")!,
      isLocalManaged: false,
      isDefault: false
    )
    let preferred = ServerEndpoint(
      name: "Preferred",
      wsURL: URL(string: "ws://10.0.0.6:4000/ws")!,
      isLocalManaged: false,
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

  @Test func resolvedEndpointIDFallsBackToPreferredConfiguredEndpoint() {
    let disabledDefault = ServerEndpoint(
      name: "Disabled Default",
      wsURL: URL(string: "ws://10.0.0.5:4000/ws")!,
      isLocalManaged: false,
      isEnabled: false,
      isDefault: true
    )
    let enabled = ServerEndpoint(
      name: "Enabled",
      wsURL: URL(string: "ws://10.0.0.6:4000/ws")!,
      isLocalManaged: false,
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
