import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerEndpointIdentityPlannerTests {
  @Test func identityNormalizesEquivalentWebSocketURLs() throws {
    let canonical = try #require(URL(string: "wss://dock.example.com/ws"))
    let equivalent = try #require(URL(string: "wss://Dock.Example.com:443/ws/"))

    #expect(
      ServerEndpointIdentityPlanner.identity(for: canonical)
        == ServerEndpointIdentityPlanner.identity(for: equivalent)
    )
  }

  @Test func dedupedRuntimesPreferDefaultEndpointForEquivalentURLs() throws {
    let primary = makeRuntime(
      endpoint: try ServerEndpoint(
        name: "Primary",
        wsURL: #require(URL(string: "wss://dock.example.com/ws")),
        isEnabled: true,
        isDefault: false
      )
    )
    let preferred = makeRuntime(
      endpoint: try ServerEndpoint(
        name: "Preferred",
        wsURL: #require(URL(string: "wss://Dock.Example.com:443/ws/")),
        isEnabled: true,
        isDefault: true
      )
    )

    let deduped = ServerEndpointIdentityPlanner.dedupedRuntimes([primary, preferred])

    #expect(deduped.count == 1)
    #expect(deduped.first?.endpoint.id == preferred.endpoint.id)
  }

  @Test func dedupedRuntimesPreferServerIdentityAcrossURLAliases() throws {
    let loopback = makeRuntime(
      endpoint: try ServerEndpoint(
        name: "Loopback",
        wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
        isEnabled: true,
        isDefault: true
      ),
      serverInstanceId: "server-1"
    )
    let lan = makeRuntime(
      endpoint: try ServerEndpoint(
        name: "LAN",
        wsURL: #require(URL(string: "ws://192.168.0.50:4000/ws")),
        isEnabled: true,
        isDefault: false
      ),
      serverInstanceId: "server-1"
    )

    let deduped = ServerEndpointIdentityPlanner.dedupedRuntimes([lan, loopback])

    #expect(deduped.count == 1)
    #expect(deduped.first?.endpoint.id == loopback.endpoint.id)
  }

  private func makeRuntime(
    endpoint: ServerEndpoint,
    serverInstanceId: String? = nil
  ) -> ServerRuntime {
    let runtime = ServerRuntime(endpoint: endpoint)
    runtime.endpointStore.serverInstanceId = serverInstanceId
    return runtime
  }
}
