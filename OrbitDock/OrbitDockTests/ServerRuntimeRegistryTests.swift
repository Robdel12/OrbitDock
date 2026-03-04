import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerRuntimeRegistryTests {
  @Test func startsTwoEnabledRuntimesConcurrently() throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "Local",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "Remote",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
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

  @Test func reconnectAndStopAreIsolatedPerEndpoint() throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
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

  @Test func endpointLookupReturnsScopedConnectionAndAppState() throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
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

  @Test func configurePreservesActiveEndpointWhenStillEnabled() throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
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

  @Test func startsOnlyEnabledEndpointsWhenConfiguredFromSettings() throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "Enabled Endpoint",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "Disabled Endpoint",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
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
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
      isLocalManaged: false,
      isEnabled: true,
      isDefault: false
    )

    let spyA = SpyServerConnection(endpoint: endpointA)
    let spyB = SpyServerConnection(endpoint: endpointB)
    spyA.recentProjectsResponse = [
      ServerRecentProject(path: "/Users/alice/ProjectA", sessionCount: 2, lastActive: "2026-02-23T10:00:00Z"),
    ]
    spyB.recentProjectsResponse = [
      ServerRecentProject(path: "/Users/alice/ProjectB", sessionCount: 5, lastActive: "2026-02-23T11:00:00Z"),
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

  @Test func preferredActiveEndpointDeterministicallyUsesDefaultEnabled() throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: false
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
      isLocalManaged: false,
      isEnabled: true,
      isDefault: true
    )

    let preferred = ServerRuntimeRegistry.preferredActiveEndpointID(from: [endpointA, endpointB])

    #expect(preferred == endpointB.id)
  }

  @Test func preferredActiveEndpointFallsBackToFirstEnabled() throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: false,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
      isLocalManaged: false,
      isEnabled: true,
      isDefault: false
    )

    let preferred = ServerRuntimeRegistry.preferredActiveEndpointID(from: [endpointA, endpointB])

    #expect(preferred == endpointB.id)
  }

  @Test func serverDeclaredPrimaryDoesNotOverrideClientControlPlaneEndpoint() async throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "Fallback",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "Declared Primary",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
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

    #expect(registry.primaryEndpointId == endpointA.id)
    #expect(registry.serverPrimaryByEndpointId[endpointB.id] == true)
  }

  @Test func multipleDeclaredPrimariesSetConflictFlag() async throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: false
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
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

  @Test func settingPrimaryRoleDemotesPeerEndpoints() throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
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
    registry.setServerRole(endpointId: endpointB.id, isPrimary: true)

    #expect(spies[endpointA.id]?.setServerRoleCalls == [false])
    #expect(spies[endpointB.id]?.setServerRoleCalls == [true])
  }

  @Test func syncsClientPrimaryClaimsFromClientControlPlaneEndpoint() async throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
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
      },
      clientIdentityProvider: {
        ServerClientIdentity(clientId: "device-1", deviceName: "Test iPhone")
      }
    )

    registry.configureFromSettings(startEnabled: false)
    await Task.yield()

    let claimsA = try #require(spies[endpointA.id]?.setClientPrimaryClaimCalls)
    let claimsB = try #require(spies[endpointB.id]?.setClientPrimaryClaimCalls)
    let lastA = try #require(claimsA.last)
    let lastB = try #require(claimsB.last)
    #expect(lastA.0 == "device-1")
    #expect(lastA.1 == "Test iPhone")
    #expect(lastA.2)
    #expect(lastB.0 == "device-1")
    #expect(lastB.1 == "Test iPhone")
    #expect(lastB.2 == false)
  }

  @Test func memoryPressureTrimsInactivePayloadsAcrossAllRuntimes() throws {
    let endpointA = try ServerEndpoint(
      id: UUID(),
      name: "A",
      wsURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try ServerEndpoint(
      id: UUID(),
      name: "B",
      wsURL: #require(URL(string: "ws://10.0.0.2:4100/ws")),
      isLocalManaged: false,
      isEnabled: true,
      isDefault: false
    )

    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpointA, endpointB] },
      runtimeFactory: { endpoint in
        let spy = SpyServerConnection(endpoint: endpoint)
        return ServerRuntime(endpoint: endpoint, connection: spy)
      }
    )

    registry.configureFromSettings(startEnabled: false)

    let appStateA = registry.appState(for: endpointA.id, fallback: ServerAppState())
    let appStateB = registry.appState(for: endpointB.id, fallback: ServerAppState())
    let sessionA = appStateA.session("session-a")
    let sessionB = appStateB.session("session-b")

    sessionA.messages = [makeMessage(id: "a-1", content: "a")]
    sessionB.messages = [makeMessage(id: "b-1", content: "b")]
    #expect(sessionA.messagesRevision == 0)
    #expect(sessionB.messagesRevision == 0)

    registry.handleMemoryPressure()

    #expect(sessionA.messages.isEmpty)
    #expect(sessionB.messages.isEmpty)
    #expect(sessionA.messagesRevision == 1)
    #expect(sessionB.messagesRevision == 1)
  }

  @Test func activeAccessorsRemainAvailableWhenNoEndpointsConfigured() {
    var runtimeFactoryCallCount = 0
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [] },
      runtimeFactory: { endpoint in
        runtimeFactoryCallCount += 1
        return ServerRuntime(endpoint: endpoint)
      }
    )

    let appState = registry.activeAppState
    let connection = registry.activeConnection

    #if os(iOS)
      // iOS does not synthesize a localhost runtime fallback when no endpoints exist.
      #expect(runtimeFactoryCallCount == 0)
      #expect(registry.runtimesByEndpointId.isEmpty)
      #expect(registry.activeEndpointId == nil)
    #else
      // macOS synthesizes a local default runtime to keep accessors available.
      #expect(runtimeFactoryCallCount == 1)
      #expect(registry.runtimesByEndpointId.count == 1)
      #expect(registry.activeEndpointId != nil)
    #endif

    #expect(appState.endpointId == connection.endpointId)
  }

  private func makeMessage(id: String, content: String) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      type: .assistant,
      content: content,
      timestamp: Date(timeIntervalSince1970: 1),
      toolName: nil,
      toolInput: nil,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )
  }
}

@MainActor
private final class SpyServerConnection: ServerConnection {
  var connectCalls: [URL] = []
  var disconnectCount = 0
  var recentProjectsResponse: [ServerRecentProject] = []
  var listRecentProjectsCallCount = 0
  var setServerRoleCalls: [Bool] = []
  var setClientPrimaryClaimCalls: [(String, String, Bool)] = []

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

  override func setServerRole(isPrimary: Bool) {
    setServerRoleCalls.append(isPrimary)
  }

  override func setClientPrimaryClaim(clientId: String, deviceName: String, isPrimary: Bool) {
    setClientPrimaryClaimCalls.append((clientId, deviceName, isPrimary))
  }
}
