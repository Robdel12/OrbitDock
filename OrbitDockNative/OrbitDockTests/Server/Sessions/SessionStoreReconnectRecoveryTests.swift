import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionStoreReconnectRecoveryTests {
  fileprivate nonisolated static let fixtureServerVersion = "0.9.0"
  fileprivate nonisolated static let fixtureMinimumClientVersion = "0.4.0"

  @Test func bootstrapFetchIsSingleFlightForTheSameGeneration() async throws {
    let counter = RequestCounter()
    let store = try makeStore(
      loader: { request in try await counter.loader(request) },
      connection: SessionStoreConnectionSpy()
    )
    store.subscribedSessions.insert("session-1")
    store.connectionGeneration = 3

    async let first = store.hydrateSessionFromHTTPBootstrap(sessionId: "session-1", generation: 3)
    async let second = store.hydrateSessionFromHTTPBootstrap(sessionId: "session-1", generation: 3)
    let firstBootstrap = await first
    let secondBootstrap = await second

    #expect(firstBootstrap != nil)
    #expect(secondBootstrap != nil)
    #expect(await counter.conversationRequestCount == 1)
    #expect(store.session("session-1").conversationLoaded == true)
    #expect(store.session("session-1").rowEntries.isEmpty)
  }

  @Test func recoveryHelperSendsSubscribeOnceForTheSameGeneration() async throws {
    let counter = RequestCounter()
    let connection = SessionStoreConnectionSpy()
    let store = try makeStore(
      loader: { request in try await counter.loader(request) }, connection: connection
    )
    store.subscribedSessions.insert("session-1")
    store.connectionGeneration = 4

    async let first: Void = store.ensureSessionRecovery("session-1", generation: 4)
    async let second: Void = store.ensureSessionRecovery("session-1", generation: 4)
    _ = await (first, second)

    #expect(await counter.conversationRequestCount == 1)
    #expect(connection.subscribeCalls.count == 3)
    #expect(connection.subscribeCalls.allSatisfy { $0.sessionId == "session-1" })
    #expect(
      Set(connection.subscribeCalls.map(\.surface))
        == Set([.detail, .composer, .conversation])
    )
    #expect(connection.subscribeCalls.first(where: { $0.surface == .detail })?.sinceRevision == 13)
    #expect(connection.subscribeCalls.first(where: { $0.surface == .composer })?.sinceRevision == 13)
    #expect(connection.subscribeCalls.first(where: { $0.surface == .conversation })?.sinceRevision == 13)
    #expect(store.recoveredSessionGenerations["session-1"] == 4)
  }

  @Test func recoverySubscribesOnlyRequestedSurfaces() async throws {
    let counter = RequestCounter()
    let connection = SessionStoreConnectionSpy()
    let store = try makeStore(
      loader: { request in try await counter.loader(request) }, connection: connection
    )
    store.subscribedSessions.insert("session-1")
    store.subscribedSessionSurfaces["session-1"] = [.composer]
    store.connectionGeneration = 5

    await store.ensureSessionRecovery("session-1", generation: 5)

    #expect(connection.subscribeCalls.count == 1)
    #expect(connection.subscribeCalls.first?.surface == .composer)
    #expect(connection.subscribeCalls.first?.sinceRevision == 13)
  }

  @Test func addingSurfaceAfterRecoveryResubscribesWithoutReconnect() async throws {
    let counter = RequestCounter()
    let connection = SessionStoreConnectionSpy()
    let store = try makeStore(
      loader: { request in try await counter.loader(request) }, connection: connection
    )
    store.subscribedSessions.insert("session-1")
    store.subscribedSessionSurfaces["session-1"] = [.detail]
    store.connectionGeneration = 6

    await store.ensureSessionRecovery("session-1", generation: 6)
    #expect(connection.subscribeCalls.count == 1)
    #expect(connection.subscribeCalls.first?.surface == .detail)
    #expect(connection.subscribeCalls.first?.sinceRevision == 13)

    connection.clearSubscribeCalls()
    store.subscribeToSession("session-1", surfaces: [.composer])
    await store.ensureSessionRecovery("session-1", generation: 6)

    #expect(connection.subscribeCalls.count == 1)
    #expect(connection.subscribeCalls.first?.surface == .composer)
    #expect(connection.subscribeCalls.first?.sinceRevision == 13)
    #expect(store.recoveredSessionGenerations["session-1"] == 6)
  }

  @Test func unsubscribeDropsInFlightBootstrapResults() async throws {
    let fixture = BlockingBootstrapFixture()
    let store = try makeStore(
      loader: { request in try await fixture.loader(request: request) },
      connection: SessionStoreConnectionSpy()
    )
    store.subscribedSessions.insert("session-1")
    store.connectionGeneration = 8

    async let bootstrap = store.hydrateSessionFromHTTPBootstrap(
      sessionId: "session-1", generation: 8
    )
    await fixture.waitForBootstrapStart()
    store.unsubscribeFromSession("session-1")
    await fixture.releaseBootstrap()
    let result = await bootstrap

    #expect(result == nil)
    #expect(store.session("session-1").rowEntries.isEmpty)
    #expect(store.session("session-1").conversationLoaded == false)
  }

  @Test func generationChangesDropStaleBootstrapResults() async throws {
    let fixture = BlockingBootstrapFixture()
    let store = try makeStore(
      loader: { request in try await fixture.loader(request: request) },
      connection: SessionStoreConnectionSpy()
    )
    store.subscribedSessions.insert("session-1")
    store.connectionGeneration = 11

    async let bootstrap = store.hydrateSessionFromHTTPBootstrap(
      sessionId: "session-1", generation: 11
    )
    await fixture.waitForBootstrapStart()
    store.connectionGeneration = 12
    await fixture.releaseBootstrap()
    let result = await bootstrap

    #expect(result == nil)
    #expect(store.session("session-1").rowEntries.isEmpty)
    #expect(store.session("session-1").conversationLoaded == false)
  }

  @Test func missingSessionBootstrapDoesNotFailEndpointConnection() async throws {
    let connection = SessionStoreConnectionSpy()
    let store = try makeStore(
      loader: { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 404,
          httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        )!
        let body = Data(#"{"code":"not_found","error":"Session session-1 not found"}"#.utf8)
        return (body, response)
      },
      connection: connection
    )
    store.subscribedSessions.insert("session-1")
    store.connectionGeneration = 13

    let result = await store.hydrateSessionFromHTTPBootstrap(sessionId: "session-1", generation: 13)

    #expect(result == nil)
    #expect(connection.failedConnectionMessages.isEmpty)
    #expect(store.session("session-1").conversationLoaded == false)
  }

  private func makeStore(
    loader: @escaping ServerClients.DataLoader,
    connection: any SessionStoreConnection
  ) throws -> SessionStore {
    let baseURL = try #require(URL(string: "http://127.0.0.1:4000"))
    let clients = ServerClients(serverURL: baseURL, authToken: nil, dataLoader: loader)
    return SessionStore(
      clients: clients,
      connection: connection,
      endpointId: UUID()
    )
  }

  fileprivate nonisolated static func makeHTTPResponse(for url: URL, json: String) -> (
    Data, URLResponse
  ) {
    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "application/json",
        "X-OrbitDock-Server-Version": fixtureServerVersion,
        "X-OrbitDock-Minimum-Client-Version": fixtureMinimumClientVersion,
      ]
    )!
    return (Data(json.utf8), response)
  }

  fileprivate nonisolated static func sessionJSON(revision: UInt64) -> String {
    """
    {
      "id": "session-1",
      "provider": "claude",
      "project_path": "/tmp/project",
      "status": "active",
      "work_status": "waiting",
      "control_mode": "direct",
      "lifecycle_state": "open",
      "accepts_user_input": true,
      "steerable": false,
      "rows": [],
      "total_row_count": 0,
      "has_more_before": false,
      "token_usage": {
        "input_tokens": 0,
        "output_tokens": 0,
        "cached_tokens": 0,
        "context_window": 0
      },
      "token_usage_snapshot_kind": "unknown",
      "allow_bypass_permissions": false,
      "turn_count": 0,
      "turn_diffs": [],
      "subagents": [],
      "is_worktree": false,
      "unread_count": 0,
      "has_pending_approval": false,
      "claude_integration_mode": "direct",
      "revision": \(revision)
    }
    """
  }

  fileprivate nonisolated static var conversationResponseJSON: String {
    """
    {
      "revision": 13,
      "session_id": "session-1",
      "session": \(sessionJSON(revision: 13)),
      "rows": [],
      "total_row_count": 0,
      "has_more_before": false,
      "oldest_sequence": null,
      "newest_sequence": null
    }
    """
  }
}

@MainActor
final class SessionStoreConnectionSpy: SessionStoreConnection {
  struct SubscribeCall {
    let sessionId: String
    let surface: ServerSessionSurface
    let sinceRevision: UInt64?
  }

  var connectionStatus: ConnectionStatus = .connected
  var isRemote: Bool = false
  private(set) var subscribeCalls: [SubscribeCall] = []
  private(set) var appliedSessionLists: [[ServerSessionListItem]] = []
  private(set) var appliedDashboardConversations: [[ServerDashboardConversationItem]] = []
  private(set) var failedConnectionMessages: [String] = []

  func addListener(_ listener: @escaping (ServerEvent) -> Void) -> ServerConnectionListenerToken {
    unsafeBitCast(UUID(), to: ServerConnectionListenerToken.self)
  }

  func removeListener(_ token: ServerConnectionListenerToken) {}

  func subscribeSessionSurface(
    _ sessionId: String, surface: ServerSessionSurface, sinceRevision: UInt64?
  ) {
    subscribeCalls.append(
      SubscribeCall(
        sessionId: sessionId,
        surface: surface,
        sinceRevision: sinceRevision
      )
    )
  }

  func unsubscribeSessionSurface(_ sessionId: String, surface: ServerSessionSurface) {}

  func clearSubscribeCalls() {
    subscribeCalls.removeAll()
  }

  func failConnection(message: String) {
    failedConnectionMessages.append(message)
  }

  func applySessionsList(_ sessions: [ServerSessionListItem]) {
    appliedSessionLists.append(sessions)
  }

  func applyDashboardConversations(_ conversations: [ServerDashboardConversationItem]) {
    appliedDashboardConversations.append(conversations)
  }
}

actor RequestCounter {
  private(set) var conversationRequestCount = 0

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    conversationRequestCount += 1
    return SessionStoreReconnectRecoveryTests.makeHTTPResponse(
      for: request.url!,
      json: SessionStoreReconnectRecoveryTests.conversationResponseJSON
    )
  }
}

actor BlockingBootstrapFixture {
  private var bootstrapStarted = false
  private var bootstrapStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var bootstrapReleased = false
  private var bootstrapReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  func loader(request: URLRequest) async throws -> (Data, URLResponse) {
    bootstrapStarted = true
    for waiter in bootstrapStartWaiters {
      waiter.resume()
    }
    bootstrapStartWaiters.removeAll()

    if !bootstrapReleased {
      await withCheckedContinuation { continuation in
        bootstrapReleaseWaiters.append(continuation)
      }
    }

    return SessionStoreReconnectRecoveryTests.makeHTTPResponse(
      for: request.url!,
      json: SessionStoreReconnectRecoveryTests.conversationResponseJSON
    )
  }

  func waitForBootstrapStart() async {
    if bootstrapStarted {
      return
    }

    await withCheckedContinuation { continuation in
      bootstrapStartWaiters.append(continuation)
    }
  }

  func releaseBootstrap() {
    bootstrapReleased = true
    for waiter in bootstrapReleaseWaiters {
      waiter.resume()
    }
    bootstrapReleaseWaiters.removeAll()
  }
}
