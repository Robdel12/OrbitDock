import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerRuntimeRegistryTests {
  @Test func startsTwoEnabledRuntimesConcurrently() {
    let endpointA = ServerEndpoint(
      id: UUID(),
      name: "Local",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = ServerEndpoint(
      id: UUID(),
      name: "Remote",
      wsURL: URL(string: "ws://10.0.0.2:4100/ws")!,
      isLocalManaged: false,
      isEnabled: true,
      isDefault: false
    )

    var spies: [UUID: SpyServerConnection] = [:]

    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpointA, endpointB] },
      runtimeFactory: { endpoint in
        let spy = SpyServerConnection(endpoint: endpoint)
        spies[endpoint.id] = spy
        return ServerRuntime(endpoint: endpoint, connection: spy)
      }
    )

    registry.configureFromSettings(startEnabled: true)

    #expect(registry.runtimesByEndpointId.count == 2)
    #expect(spies[endpointA.id]?.connectCalls == [endpointA.wsURL])
    #expect(spies[endpointB.id]?.connectCalls == [endpointB.wsURL])
  }

  @Test func reconnectAndStopAreIsolatedPerEndpoint() {
    let endpointA = ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: URL(string: "ws://10.0.0.2:4100/ws")!,
      isLocalManaged: false,
      isEnabled: true,
      isDefault: false
    )

    var spies: [UUID: SpyServerConnection] = [:]
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpointA, endpointB] },
      runtimeFactory: { endpoint in
        let spy = SpyServerConnection(endpoint: endpoint)
        spies[endpoint.id] = spy
        return ServerRuntime(endpoint: endpoint, connection: spy)
      }
    )

    registry.configureFromSettings(startEnabled: true)

    registry.reconnect(endpointId: endpointA.id)

    #expect(spies[endpointA.id]?.disconnectCount == 1)
    #expect(spies[endpointA.id]?.connectCalls.count == 2)
    #expect(spies[endpointB.id]?.disconnectCount == 0)
    #expect(spies[endpointB.id]?.connectCalls.count == 1)

    registry.stop(endpointId: endpointB.id)

    #expect(spies[endpointB.id]?.disconnectCount == 1)
    #expect(spies[endpointA.id]?.disconnectCount == 1)
  }

  @Test func callbackStateIsNotSharedAcrossRuntimeConnections() {
    let endpointA = ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: URL(string: "ws://10.0.0.2:4100/ws")!,
      isLocalManaged: false,
      isEnabled: true,
      isDefault: false
    )

    let runtimeA = ServerRuntime(endpoint: endpointA, connection: SpyServerConnection(endpoint: endpointA))
    let runtimeB = ServerRuntime(endpoint: endpointB, connection: SpyServerConnection(endpoint: endpointB))

    var invokedA = false
    var invokedB = false

    runtimeA.connection.onOpenAiKeyStatus = { _ in invokedA = true }
    runtimeB.connection.onOpenAiKeyStatus = { _ in invokedB = true }

    runtimeA.connection.onOpenAiKeyStatus?(true)

    #expect(invokedA)
    #expect(!invokedB)

    runtimeB.connection.onOpenAiKeyStatus?(false)

    #expect(invokedA)
    #expect(invokedB)
  }
}

@MainActor
private final class SpyServerConnection: ServerConnection {
  var connectCalls: [URL] = []
  var disconnectCount = 0

  override func connect(to url: URL) {
    connectCalls.append(url)
  }

  override func disconnect() {
    disconnectCount += 1
  }
}
