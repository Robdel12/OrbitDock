import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionStoreReconnectRecoveryTests {
  fileprivate nonisolated static let fixtureServerVersion = "0.9.0"
  fileprivate nonisolated static let fixtureMinimumClientVersion = "0.4.0"
  fileprivate nonisolated static let recoveredSessionSurfaces: SessionSurfaceSet = Set(
    ServerSessionSurface.allCases
  )

  @Test func bootstrapFetchIsSingleFlightForTheSameGeneration() async throws {
    let counter = RequestCounter()
    let store = try makeStore(
      loader: { request in try await counter.loader(request) },
      connection: SessionStoreConnectionSpy()
    )
    prepareRecoveryStore(store, generation: 3)

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
    prepareRecoveryStore(store, generation: 4)

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
    prepareRecoveryStore(store, generation: 5, surfaces: [.composer])

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
    prepareRecoveryStore(store, generation: 6, surfaces: [.detail])

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

  @Test func forceRecoveryResubscribesEvenWhenSessionWasAlreadyRecovered() async throws {
    let counter = RequestCounter()
    let connection = SessionStoreConnectionSpy()
    let store = try makeStore(
      loader: { request in try await counter.loader(request) }, connection: connection
    )
    prepareRecoveryStore(store, generation: 7, surfaces: Self.recoveredSessionSurfaces)

    await store.ensureSessionRecovery("session-1", generation: 7)
    let baselineRequests = await counter.conversationRequestCount
    connection.clearSubscribeCalls()

    store.subscribeToSession("session-1", forceRecovery: true)
    await store.ensureSessionRecovery("session-1", generation: 7)

    #expect(await counter.conversationRequestCount == baselineRequests + 1)
    #expect(connection.subscribeCalls.count == 3)
    #expect(
      Set(connection.subscribeCalls.map(\.surface))
        == Set([.detail, .composer, .conversation])
    )
  }

  @Test func resumeSessionReconcilesConversationBeforeReturning() async throws {
    let fixture = ResumeAndConversationMutationFixture()
    let store = try makeStore(
      loader: { request in try await fixture.loader(request) },
      connection: SessionStoreConnectionSpy()
    )
    store.connectionGeneration = 8

    try await store.resumeSession("session-1")

    #expect(await fixture.resumeRequestCount == 1)
    #expect(await fixture.conversationRequestCount == 1)
    #expect(store.session("session-1").conversationLoaded == true)
    #expect(store.session("session-1").lifecycleState == .open)
    #expect(store.session("session-1").acceptsUserInput == true)
    #expect(store.session("session-1").rowEntries.contains(where: { $0.id == "bootstrap-row-1" }))
  }

  @Test func sendMessageReconcilesConversationWithBootstrapState() async throws {
    let fixture = ResumeAndConversationMutationFixture()
    let store = try makeStore(
      loader: { request in try await fixture.loader(request) },
      connection: SessionStoreConnectionSpy()
    )
    prepareRecoveryStore(store, generation: 9)

    try await store.sendMessage(sessionId: "session-1", content: "hello from test")

    #expect(await fixture.sendMessageRequestCount == 1)
    #expect(await fixture.conversationRequestCount == 1)
    #expect(store.session("session-1").conversationLoaded == true)
    #expect(store.session("session-1").rowEntries.contains(where: { $0.id == "bootstrap-row-1" }))
  }

  @Test func unsubscribeDropsInFlightBootstrapResults() async throws {
    let fixture = BlockingBootstrapFixture()
    let store = try makeStore(
      loader: { request in try await fixture.loader(request: request) },
      connection: SessionStoreConnectionSpy()
    )
    prepareRecoveryStore(store, generation: 8)

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
    prepareRecoveryStore(store, generation: 11)

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
    prepareRecoveryStore(store, generation: 13)

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

  private func prepareRecoveryStore(
    _ store: SessionStore,
    generation: UInt64,
    surfaces: SessionSurfaceSet? = nil,
    sessionId: String = "session-1"
  ) {
    store.subscribedSessions.insert(sessionId)
    if let surfaces {
      store.subscribedSessionSurfaces[sessionId] = surfaces
    }
    store.connectionGeneration = generation
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
    conversationResponseJSON(rowsJSON: "[]")
  }

  fileprivate nonisolated static func conversationResponseJSON(rowsJSON: String) -> String {
    """
    {
      "revision": 13,
      "session_id": "session-1",
      "session": \(sessionJSON(revision: 13)),
      "rows": \(rowsJSON),
      "total_row_count": 0,
      "has_more_before": false,
      "oldest_sequence": null,
      "newest_sequence": null
    }
    """
  }

  fileprivate nonisolated static var resumeSessionResponseJSON: String {
    """
    {
      "session_id": "session-1",
      "session": \(sessionSummaryJSON)
    }
    """
  }

  fileprivate nonisolated static var sessionSummaryJSON: String {
    """
    {
      "id": "session-1",
      "provider": "claude",
      "project_path": "/tmp/project",
      "project_name": "OrbitDock",
      "status": "active",
      "work_status": "waiting",
      "control_mode": "direct",
      "lifecycle_state": "open",
      "accepts_user_input": true,
      "steerable": false,
      "token_usage": {
        "input_tokens": 0,
        "output_tokens": 0,
        "cached_tokens": 0,
        "context_window": 0
      },
      "token_usage_snapshot_kind": "unknown",
      "has_pending_approval": false,
      "allow_bypass_permissions": false,
      "is_worktree": false,
      "unread_count": 0,
      "display_title": "OrbitDock Session",
      "list_status": "reply",
      "summary_revision": 1
    }
    """
  }

  fileprivate nonisolated static var bootstrapRowJSON: String {
    """
    {
      "session_id": "session-1",
      "sequence": 10,
      "turn_id": "turn-1",
      "row": {
        "row_type": "user",
        "id": "bootstrap-row-1",
        "content": "hello from bootstrap",
        "is_streaming": false
      }
    }
    """
  }

  fileprivate nonisolated static var sendMessageResponseJSON: String {
    """
    {
      "accepted": true,
      "row": {
        "session_id": "session-1",
        "sequence": 9,
        "turn_id": "turn-1",
        "row": {
          "row_type": "user",
          "id": "send-row-1",
          "content": "hello from send",
          "is_streaming": false
        }
      }
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

actor ResumeAndConversationMutationFixture {
  private(set) var conversationRequestCount = 0
  private(set) var resumeRequestCount = 0
  private(set) var sendMessageRequestCount = 0

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let path = request.url?.path ?? ""

    if path.hasSuffix("/resume") {
      resumeRequestCount += 1
      return SessionStoreReconnectRecoveryTests.makeHTTPResponse(
        for: request.url!,
        json: SessionStoreReconnectRecoveryTests.resumeSessionResponseJSON
      )
    }

    if path.hasSuffix("/messages"), request.httpMethod == "POST" {
      sendMessageRequestCount += 1
      return SessionStoreReconnectRecoveryTests.makeHTTPResponse(
        for: request.url!,
        json: SessionStoreReconnectRecoveryTests.sendMessageResponseJSON
      )
    }

    if path.hasSuffix("/conversation") {
      conversationRequestCount += 1
      let rowsJSON = "[\(SessionStoreReconnectRecoveryTests.bootstrapRowJSON)]"
      return SessionStoreReconnectRecoveryTests.makeHTTPResponse(
        for: request.url!,
        json: SessionStoreReconnectRecoveryTests.conversationResponseJSON(rowsJSON: rowsJSON)
      )
    }

    if path.hasSuffix("/approvals") {
      return SessionStoreReconnectRecoveryTests.makeHTTPResponse(
        for: request.url!,
        json: #"{"approvals":[]}"#
      )
    }

    throw URLError(.badURL)
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
