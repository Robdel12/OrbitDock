import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerSessionListRefreshTests {
  @Test func runtimesStayInStableDisplayOrder() throws {
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

    let orderedRuntimeIds = registry.runtimes.map(\.endpoint.id)

    #expect(orderedRuntimeIds == [disabled.id, enabledB.id, enabledA.id])
  }

  @Test func endpointLookupWithExplicitMissingIdDoesNotFallbackToActiveEndpoint() throws {
    let active = try makeEndpoint(
      id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      name: "Active",
      isEnabled: true,
      isDefault: true,
      port: 4_101
    )
    let secondary = try makeEndpoint(
      id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      name: "Secondary",
      isEnabled: true,
      isDefault: false,
      port: 4_102
    )
    let missingId = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [active, secondary] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)
    registry.setActiveEndpoint(id: active.id)

    let store = registry.endpointStore(for: missingId)

    #expect(store.endpointId != active.id)
    #expect(store.clients.baseURL.host == "127.0.0.1")
    #expect(store.clients.baseURL.port == 3000)
  }

  @Test func nilEndpointLookupUsesActiveEndpointForCreationFlow() throws {
    let active = try makeEndpoint(
      id: "dddddddd-dddd-dddd-dddd-dddddddddddd",
      name: "Active",
      isEnabled: true,
      isDefault: true,
      port: 4_111
    )
    let secondary = try makeEndpoint(
      id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
      name: "Secondary",
      isEnabled: true,
      isDefault: false,
      port: 4_112
    )

    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [active, secondary] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)
    registry.setActiveEndpoint(id: secondary.id)

    let store = registry.endpointStore(for: nil)

    #expect(store.endpointId == secondary.id)
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
      isEnabled: isEnabled,
      isDefault: isDefault
    )
  }
}
