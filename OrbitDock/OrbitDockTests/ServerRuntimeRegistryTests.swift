import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerRuntimeRegistryTests {
  @Test func configureCreatesEndpointScopedRuntimesAndPicksPreferredActiveEndpoint() throws {
    let endpointA = try makeEndpoint(
      id: "11111111-1111-1111-1111-111111111111",
      name: "Alpha",
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try makeEndpoint(
      id: "22222222-2222-2222-2222-222222222222",
      name: "Beta",
      isEnabled: true,
      isDefault: false
    )

    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpointA, endpointB] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )

    registry.configureFromSettings(startEnabled: false)

    #expect(registry.runtimesByEndpointId.count == 2)
    #expect(registry.activeEndpointId == endpointA.id)
    #expect(registry.sessionStore(for: endpointA.id, fallback: SessionStore()).endpointId == endpointA.id)
    #expect(registry.sessionStore(for: endpointB.id, fallback: SessionStore()).endpointId == endpointB.id)
  }

  @Test func configurePreservesActiveEndpointWhenItRemainsEnabled() throws {
    let endpointA = try makeEndpoint(
      id: "33333333-3333-3333-3333-333333333333",
      name: "Alpha",
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try makeEndpoint(
      id: "44444444-4444-4444-4444-444444444444",
      name: "Beta",
      isEnabled: true,
      isDefault: false
    )

    var endpoints = [endpointA, endpointB]
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { endpoints },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )

    registry.configureFromSettings(startEnabled: false)
    registry.setActiveEndpoint(id: endpointB.id)
    #expect(registry.activeEndpointId == endpointB.id)

    endpoints = [
      endpointA,
      try makeEndpoint(
        id: endpointB.id.uuidString,
        name: endpointB.name,
        isEnabled: true,
        isDefault: false,
        port: 4_100
      ),
    ]

    registry.configureFromSettings(startEnabled: false)

    #expect(registry.activeEndpointId == endpointB.id)
  }

  @Test func sessionStoreLookupFallsBackForUnknownEndpoints() throws {
    let endpoint = try makeEndpoint(
      id: "55555555-5555-5555-5555-555555555555",
      name: "Solo",
      isEnabled: true,
      isDefault: true
    )
    let fallback = SessionStore()
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )

    registry.configureFromSettings(startEnabled: false)

    #expect(registry.sessionStore(for: endpoint.id, fallback: fallback).endpointId == endpoint.id)
    #expect(registry.sessionStore(for: nil, fallback: fallback).endpointId == fallback.endpointId)
    #expect(registry.sessionStore(for: UUID(), fallback: fallback).endpointId == fallback.endpointId)
  }

  @Test func handleMemoryPressureClearsInactiveConversationStores() throws {
    let endpointA = try makeEndpoint(
      id: "66666666-6666-6666-6666-666666666666",
      name: "Alpha",
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try makeEndpoint(
      id: "77777777-7777-7777-7777-777777777777",
      name: "Beta",
      isEnabled: true,
      isDefault: false
    )

    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpointA, endpointB] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )

    registry.configureFromSettings(startEnabled: false)

    let fallback = SessionStore()
    let storeB = registry.sessionStore(for: endpointB.id, fallback: fallback)

    storeB.conversation("trimmed").restoreFromCache(
      CachedConversation(
        messages: [makeMessage(id: "b-1", content: "trimmed")],
        totalMessageCount: 1,
        oldestSequence: 1,
        newestSequence: 1,
        hasMoreHistoryBefore: false,
        cachedAt: Date()
      )
    )

    registry.handleMemoryPressure()

    #expect(storeB.conversation("trimmed").messages.isEmpty)
  }

  @Test func activeSessionStoreSynthesizesLocalFallbackWhenBootstrapIsDisabled() {
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )

    let activeStore = registry.activeSessionStore

    #expect(registry.runtimesByEndpointId.count == 1)
    #expect(registry.activeEndpointId != nil)
    #expect(activeStore.endpointId == registry.activeEndpointId)
  }

  @Test func preferredActiveEndpointIDFallsBackFromDefaultToFirstEnabled() throws {
    let disabledDefault = try makeEndpoint(
      id: "88888888-8888-8888-8888-888888888888",
      name: "Disabled Default",
      isEnabled: false,
      isDefault: true
    )
    let enabled = try makeEndpoint(
      id: "99999999-9999-9999-9999-999999999999",
      name: "Enabled",
      isEnabled: true,
      isDefault: false
    )

    #expect(ServerRuntimeRegistry.preferredActiveEndpointID(from: [disabledDefault, enabled]) == enabled.id)
  }

  @Test func primaryClaimPlannerOnlyReturnsChangedAssignmentsForEnabledEndpoints() throws {
    let endpointA = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let endpointB = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
    let endpointC = try #require(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc"))

    let updates = ServerPrimaryClaimPlanner.updates(
      enabledEndpointIds: [endpointA, endpointB],
      primaryEndpointId: endpointB,
      previousAssignments: [
        endpointA: false,
        endpointB: false,
        endpointC: true,
      ]
    )

    #expect(updates == [
      ServerPrimaryClaimUpdate(endpointId: endpointB, isPrimary: true)
    ])
  }

  @Test func configureWithoutStartingDoesNotEmitPrimaryClaimWrites() async throws {
    let endpointA = try makeEndpoint(
      id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      name: "Alpha",
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try makeEndpoint(
      id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      name: "Beta",
      isEnabled: true,
      isDefault: false,
      port: 4_100
    )
    let recorder = RuntimeRequestRecorder()
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpointA, endpointB] },
      runtimeFactory: { endpoint in
        makeRecordingRuntime(endpoint: endpoint, recorder: recorder)
      },
      shouldBootstrapFromSettings: false
    )

    registry.configureFromSettings(startEnabled: false)
    await registry.waitForControlPlaneIdleForTests()

    let claimRequests = await recorder.requests(matchingPath: "/api/client/primary-claim")
    #expect(claimRequests.isEmpty)
  }

  @Test func configureWhenStartingEmitsOneDeterministicPrimaryClaimPass() async throws {
    let endpointA = try makeEndpoint(
      id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      name: "Alpha",
      isEnabled: true,
      isDefault: true
    )
    let endpointB = try makeEndpoint(
      id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      name: "Beta",
      isEnabled: true,
      isDefault: false,
      port: 4_100
    )
    let recorder = RuntimeRequestRecorder()
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpointA, endpointB] },
      runtimeFactory: { endpoint in
        makeRecordingRuntime(endpoint: endpoint, recorder: recorder)
      },
      shouldBootstrapFromSettings: false
    )

    registry.configureFromSettings(startEnabled: true)
    await registry.waitForControlPlaneIdleForTests()

    let claimRequests = await recorder.requests(matchingPath: "/api/client/primary-claim")
    #expect(claimRequests.count == 2)

    let requestBodies = try claimRequests.map { request -> [String: Any] in
      let body = try #require(request.httpBody)
      return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    #expect(requestBodies.map { $0["is_primary"] as? Bool } == [true, false])
  }

  private func makeMessage(id: String, content: String) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: 1,
      type: .assistant,
      content: content,
      timestamp: Date(timeIntervalSince1970: 1)
    )
  }

  private func makeEndpoint(
    id: String,
    name: String,
    isEnabled: Bool,
    isDefault: Bool,
    port: Int = 4_000
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

  private func makeRecordingRuntime(
    endpoint: ServerEndpoint,
    recorder: RuntimeRequestRecorder
  ) -> ServerRuntime {
    let apiClient = APIClient(
      serverURL: APIClient.httpBaseURL(from: endpoint.wsURL),
      authToken: endpoint.authToken,
      dataLoader: { request in
        await recorder.record(request)
        return Self.response(for: request)
      }
    )
    let eventStream = EventStream(authToken: endpoint.authToken)
    return ServerRuntime(endpoint: endpoint, apiClient: apiClient, eventStream: eventStream)
  }

  nonisolated private static func response(for request: URLRequest) -> (Data, URLResponse) {
    let path = request.url?.path ?? ""
    let json: String
    let statusCode: Int

    switch path {
      case "/api/server/role":
        json = #"{"is_primary":true}"#
        statusCode = 200
      case "/api/client/primary-claim":
        json = #"{}"#
        statusCode = 202
      default:
        json = #"{}"#
        statusCode = 200
    }

    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "http://127.0.0.1")!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(json.utf8), response)
  }
}

private actor RuntimeRequestRecorder {
  private var requestsByPath: [String: [URLRequest]] = [:]

  func record(_ request: URLRequest) {
    let path = request.url?.path ?? ""
    requestsByPath[path, default: []].append(request)
  }

  func requests(matchingPath path: String) -> [URLRequest] {
    requestsByPath[path] ?? []
  }
}
