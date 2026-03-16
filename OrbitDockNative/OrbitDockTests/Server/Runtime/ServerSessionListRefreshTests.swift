import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerSessionListRefreshTests {
  @Test func refreshTargetsOnlyEnabledEndpointsInStableRuntimeOrder() throws {
    let enabledA = try makeEndpoint(
      id: "11111111-1111-1111-1111-111111111111",
      name: "Zulu",
      isEnabled: true,
      isDefault: false,
      port: 4_001
    )
    let disabled = try makeEndpoint(
      id: "22222222-2222-2222-2222-222222222222",
      name: "Alpha",
      isEnabled: false,
      isDefault: false,
      port: 4_002
    )
    let enabledB = try makeEndpoint(
      id: "33333333-3333-3333-3333-333333333333",
      name: "Bravo",
      isEnabled: true,
      isDefault: true,
      port: 4_003
    )

    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [enabledA, disabled, enabledB] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)

    let refreshed = registry.refreshEnabledSessionLists()

    #expect(refreshed == [enabledB.id, enabledA.id])
  }

  private func makeEndpoint(
    id: String,
    name: String,
    isEnabled: Bool,
    isDefault: Bool,
    port: Int
  ) throws -> ServerEndpoint {
    try ServerEndpoint(
      id: #require(UUID(uuidString: id)),
      name: name,
      wsURL: #require(URL(string: "ws://127.0.0.1:\(port)/ws")),
      isLocalManaged: true,
      isEnabled: isEnabled,
      isDefault: isDefault
    )
  }
}
