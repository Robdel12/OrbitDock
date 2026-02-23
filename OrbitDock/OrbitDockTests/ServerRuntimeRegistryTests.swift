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

  @Test func endpointLookupReturnsScopedConnectionAndAppState() {
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

    let fallback = ServerAppState()
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpointA, endpointB] },
      runtimeFactory: { endpoint in
        let spy = SpyServerConnection(endpoint: endpoint)
        return ServerRuntime(endpoint: endpoint, connection: spy)
      }
    )

    registry.configureFromSettings(startEnabled: false)

    let appStateA = registry.appState(for: endpointA.id, fallback: fallback)
    let appStateB = registry.appState(for: endpointB.id, fallback: fallback)

    #expect(appStateA.endpointId == endpointA.id)
    #expect(appStateB.endpointId == endpointB.id)
    #expect(registry.connection(for: endpointA.id)?.endpointId == endpointA.id)
    #expect(registry.connection(for: endpointB.id)?.endpointId == endpointB.id)
    #expect(registry.connection(for: nil) == nil)
    #expect(registry.appState(for: nil, fallback: fallback).endpointId == fallback.endpointId)
  }

  @Test func configurePreservesActiveEndpointWhenStillEnabled() {
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

    var endpoints = [endpointA, endpointB]
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { endpoints },
      runtimeFactory: { endpoint in
        let spy = SpyServerConnection(endpoint: endpoint)
        return ServerRuntime(endpoint: endpoint, connection: spy)
      }
    )

    registry.configureFromSettings(startEnabled: false)
    registry.setActiveEndpoint(id: endpointB.id)
    #expect(registry.activeEndpointId == endpointB.id)

    // Reconfigure with a changed default. Active endpoint should remain pinned to B.
    endpoints = [
      endpointA,
      ServerEndpoint(
        id: endpointB.id,
        name: endpointB.name,
        wsURL: endpointB.wsURL,
        isLocalManaged: false,
        isEnabled: true,
        isDefault: false
      ),
    ]

    registry.configureFromSettings(startEnabled: false)
    #expect(registry.activeEndpointId == endpointB.id)
  }

  @Test func startsOnlyEnabledEndpointsWhenConfiguredFromSettings() {
    let endpointA = ServerEndpoint(
      id: UUID(),
      name: "Enabled Endpoint",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = ServerEndpoint(
      id: UUID(),
      name: "Disabled Endpoint",
      wsURL: URL(string: "ws://10.0.0.2:4100/ws")!,
      isLocalManaged: false,
      isEnabled: false,
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

    #expect(spies[endpointA.id]?.connectCalls == [endpointA.wsURL])
    #expect(spies[endpointB.id]?.connectCalls.isEmpty == true)
    #expect(registry.activeEndpointId == endpointA.id)
  }

  @Test func requestStateIsNotSharedAcrossRuntimeConnections() async throws {
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

    let spyA = SpyServerConnection(endpoint: endpointA)
    let spyB = SpyServerConnection(endpoint: endpointB)
    spyA.recentProjectsResponse = [
      ServerRecentProject(path: "/Users/alice/ProjectA", sessionCount: 2, lastActive: "2026-02-23T10:00:00Z")
    ]
    spyB.recentProjectsResponse = [
      ServerRecentProject(path: "/Users/alice/ProjectB", sessionCount: 5, lastActive: "2026-02-23T11:00:00Z")
    ]

    let runtimeA = ServerRuntime(endpoint: endpointA, connection: spyA)
    let runtimeB = ServerRuntime(endpoint: endpointB, connection: spyB)

    let projectsA = try await runtimeA.connection.listRecentProjects()
    let projectsB = try await runtimeB.connection.listRecentProjects()

    #expect(projectsA.map(\.path) == ["/Users/alice/ProjectA"])
    #expect(projectsB.map(\.path) == ["/Users/alice/ProjectB"])
    #expect(spyA.listRecentProjectsCallCount == 1)
    #expect(spyB.listRecentProjectsCallCount == 1)
  }

  @Test func preferredActiveEndpointDeterministicallyUsesDefaultEnabled() {
    let endpointA = ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: false
    )
    let endpointB = ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: URL(string: "ws://10.0.0.2:4100/ws")!,
      isLocalManaged: false,
      isEnabled: true,
      isDefault: true
    )

    let preferred = ServerRuntimeRegistry.preferredActiveEndpointID(from: [endpointA, endpointB])

    #expect(preferred == endpointB.id)
  }

  @Test func preferredActiveEndpointFallsBackToFirstEnabled() {
    let endpointA = ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: false,
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

    let preferred = ServerRuntimeRegistry.preferredActiveEndpointID(from: [endpointA, endpointB])

    #expect(preferred == endpointB.id)
  }

  @Test func serverDeclaredPrimaryOverridesFallbackEndpoint() async {
    let endpointA = ServerEndpoint(
      id: UUID(),
      name: "Fallback",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = ServerEndpoint(
      id: UUID(),
      name: "Declared Primary",
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

    registry.configureFromSettings(startEnabled: false)
    #expect(registry.primaryEndpointId == endpointA.id)

    spies[endpointB.id]?.applyServerInfo(isPrimary: true)
    await Task.yield()

    #expect(registry.primaryEndpointId == endpointB.id)
    #expect(registry.serverPrimaryByEndpointId[endpointB.id] == true)
  }

  @Test func multipleDeclaredPrimariesSetConflictFlag() async {
    let endpointA = ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: false
    )
    let endpointB = ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: URL(string: "ws://10.0.0.2:4100/ws")!,
      isLocalManaged: false,
      isEnabled: true,
      isDefault: true
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

    registry.configureFromSettings(startEnabled: false)
    registry.setActiveEndpoint(id: endpointB.id)

    spies[endpointA.id]?.applyServerInfo(isPrimary: true)
    spies[endpointB.id]?.applyServerInfo(isPrimary: true)
    await Task.yield()

    #expect(registry.hasPrimaryEndpointConflict)
    #expect(registry.primaryEndpointId == endpointB.id)
  }
}

@MainActor
private final class SpyServerConnection: ServerConnection {
  var connectCalls: [URL] = []
  var disconnectCount = 0
  var recentProjectsResponse: [ServerRecentProject] = []
  var listRecentProjectsCallCount = 0

  override func connect(to url: URL) {
    connectCalls.append(url)
  }

  override func disconnect() {
    disconnectCount += 1
  }

  override func listRecentProjects() async throws -> [ServerRecentProject] {
    listRecentProjectsCallCount += 1
    return recentProjectsResponse
  }
}
