import Foundation
@testable import OrbitDock
import Testing

@MainActor
func makeSessionHarness(
  loader: @escaping ServerClients.DataLoader,
  connection: EndpointRuntimeConnectionSpy
) throws -> TransportSessionHarness {
  let baseURL = try #require(URL(string: "http://127.0.0.1:4000"))
  let clients = ServerClients(serverURL: baseURL, authToken: nil, dataLoader: loader)
  let runtime = ServerEndpointRuntime(
    clients: clients,
    connection: connection,
    endpointId: UUID()
  )
  return TransportSessionHarness(runtime: runtime, sessionId: "session-1", connection: connection)
}

@MainActor
final class EndpointRuntimeConnectionSpy: ServerEndpointRuntimeConnection {
  struct SubscribeCall {
    let sessionId: String
    let surface: ServerSessionSurface
    let sinceRevision: UInt64?
  }

  struct UnsubscribeCall {
    let sessionId: String
    let surface: ServerSessionSurface
  }

  var connectionStatus: ConnectionStatus = .connected
  var isRemote: Bool = false
  private(set) var subscribeCalls: [SubscribeCall] = []
  private(set) var unsubscribeCalls: [UnsubscribeCall] = []
  private var listeners: [(ServerEvent) -> Void] = []

  func addListener(_ listener: @escaping (ServerEvent) -> Void) -> ServerConnectionListenerToken {
    listeners.append(listener)
    return unsafeBitCast(UUID(), to: ServerConnectionListenerToken.self)
  }

  func removeListener(_ token: ServerConnectionListenerToken) {}
  func subscribeMissions(sinceRevision: UInt64?) {}
  func unsubscribeMissions() {}
  func subscribeMission(_ missionId: String) {}
  func unsubscribeMission(_ missionId: String) {}
  func resubscribeMission(_ missionId: String) {}

  func subscribeSessionSurface(
    _ sessionId: String,
    surface: ServerSessionSurface,
    sinceRevision: UInt64?
  ) {
    subscribeCalls.append(
      SubscribeCall(sessionId: sessionId, surface: surface, sinceRevision: sinceRevision)
    )
  }

  func unsubscribeSessionSurface(_ sessionId: String, surface: ServerSessionSurface) {
    unsubscribeCalls.append(UnsubscribeCall(sessionId: sessionId, surface: surface))
  }

  func failConnection(message: String) {}

  func clearSubscribeCalls() {
    subscribeCalls.removeAll()
  }
}

@MainActor
final class TransportSessionHarness {
  let runtime: ServerEndpointRuntime
  let session: ServerSessionContext
  let connection: EndpointRuntimeConnectionSpy

  init(runtime: ServerEndpointRuntime, sessionId: String, connection: EndpointRuntimeConnectionSpy) {
    self.runtime = runtime
    self.session = runtime.session(sessionId)
    self.connection = connection
  }
}

actor SimpleTransportFixture {
  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "application/json",
        "X-OrbitDock-Server-Version": "0.9.0",
        "X-OrbitDock-Minimum-Client-Version": "0.4.0",
      ]
    )!
    return (Data("{}".utf8), response)
  }
}

actor ConversationBootstrapFixture {
  private(set) var conversationRequestCount = 0

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let path = request.url?.path ?? ""
    guard path.hasSuffix("/conversation") else {
      throw URLError(.badURL)
    }

    conversationRequestCount += 1
    return Self.makeHTTPResponse(
      for: request.url!,
      json: Self.conversationResponseJSON
    )
  }

  fileprivate nonisolated static func makeHTTPResponse(for url: URL, json: String) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "application/json",
        "X-OrbitDock-Server-Version": "0.9.0",
        "X-OrbitDock-Minimum-Client-Version": "0.4.0",
      ]
    )!
    return (Data(json.utf8), response)
  }

  fileprivate nonisolated static var conversationResponseJSON: String {
    """
    {
      "revision": 13,
      "replay_cursor": 13,
      "session_id": "session-1",
      "forked_from_session_id": "session-root",
      "rows": [
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
      ],
      "total_row_count": 1,
      "has_more_before": false,
      "oldest_sequence": 10,
      "newest_sequence": 10
    }
    """
  }
}

actor BlockingConversationResyncFixture {
  private(set) var conversationRequestCount = 0
  private var secondConversationStarted = false
  private var secondConversationReleased = false
  private var secondConversationStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var secondConversationReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let path = request.url?.path ?? ""
    guard path.hasSuffix("/conversation") else {
      throw URLError(.badURL)
    }

    conversationRequestCount += 1
    if conversationRequestCount == 2 {
      secondConversationStarted = true
      resume(waiters: &secondConversationStartWaiters)
      if !secondConversationReleased {
        await withCheckedContinuation { continuation in
          secondConversationReleaseWaiters.append(continuation)
        }
      }
    }

    return Self.makeHTTPResponse(
      for: request.url!,
      json: Self.conversationResponseJSON
    )
  }

  func waitForSecondConversationRequest() async {
    guard !secondConversationStarted else { return }
    await withCheckedContinuation { continuation in
      secondConversationStartWaiters.append(continuation)
    }
  }

  func releaseSecondConversationRequest() {
    secondConversationReleased = true
    resume(waiters: &secondConversationReleaseWaiters)
  }

  private func resume(waiters: inout [CheckedContinuation<Void, Never>]) {
    let currentWaiters = waiters
    waiters.removeAll(keepingCapacity: false)
    currentWaiters.forEach { $0.resume() }
  }

  private nonisolated static func makeHTTPResponse(for url: URL, json: String) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "application/json",
        "X-OrbitDock-Server-Version": "0.9.0",
        "X-OrbitDock-Minimum-Client-Version": "0.4.0",
      ]
    )!
    return (Data(json.utf8), response)
  }

  private nonisolated static var conversationResponseJSON: String {
    ConversationBootstrapFixture.conversationResponseJSON
  }
}

actor ConversationMutationFixture {
  private(set) var sendMessageRequestCount = 0

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    guard let url = request.url else { throw URLError(.badURL) }
    guard (request.httpMethod ?? "GET") == "POST" else { throw URLError(.badURL) }
    guard url.path == "/api/sessions/session-1/conversation/messages" else {
      throw URLError(.badURL)
    }

    sendMessageRequestCount += 1
    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "application/json",
        "X-OrbitDock-Server-Version": "0.9.0",
        "X-OrbitDock-Minimum-Client-Version": "0.4.0",
      ]
    )!

    return (
      Data(
        """
        {
          "accepted": true,
          "row": {
            "session_id": "session-1",
            "sequence": 1,
            "turn_id": "turn-1",
            "row": {
              "row_type": "user",
              "id": "send-row-1",
              "content": "Ship it",
              "is_streaming": false
            }
          }
        }
        """.utf8
      ),
      response
    )
  }
}

actor SessionDetailRequestFixture {
  struct RequestSnapshot {
    let path: String
    let queryItems: [String: String]
  }

  private(set) var detailRequest: RequestSnapshot?

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    guard let url = request.url else { throw URLError(.badURL) }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    detailRequest = RequestSnapshot(
      path: url.path,
      queryItems: Dictionary(
        uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
      )
    )

    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "application/json",
        "X-OrbitDock-Server-Version": "0.9.0",
        "X-OrbitDock-Minimum-Client-Version": "0.4.0",
      ]
    )!

    return (
      Data(Self.sessionDetailResponseJSON.utf8),
      response
    )
  }

  private nonisolated static var sessionDetailResponseJSON: String {
    """
    {
      "revision": 7,
      "session": {
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
        "turn_count": 2,
        "turn_diffs": [],
        "subagents": [],
        "is_worktree": false,
        "unread_count": 0,
        "claude_integration_mode": "direct",
        "revision": 7
      }
    }
    """
  }
}

enum ConversationEventRecorder {
  static func collectInvalidationCounts(
    from stream: AsyncStream<ServerSessionTransport.Event>,
    until target: (ServerSessionInvalidation, Int)
  ) async -> [ServerSessionInvalidation: Int] {
    var invalidationCounts: [ServerSessionInvalidation: Int] = [:]
    for await event in stream {
      guard case let .invalidated(targets) = event else { continue }
      for invalidation in targets {
        invalidationCounts[invalidation, default: 0] += 1
      }
      if invalidationCounts[target.0, default: 0] >= target.1 {
        return invalidationCounts
      }
    }
    return invalidationCounts
  }

  static func collectRowAndConversationInvalidation(
    from stream: AsyncStream<ServerSessionTransport.Event>
  ) async -> (rowIDs: [String], conversationInvalidationCount: Int) {
    var rowIDs: [String] = []
    var conversationInvalidationCount = 0

    for await event in stream {
      switch event {
        case let .conversationRowsChanged(delta):
          let ids = await MainActor.run { delta.upserted.map(\.id) }
          rowIDs.append(contentsOf: ids)
        case let .invalidated(targets):
          if targets.contains(.conversation) {
            conversationInvalidationCount += 1
          }
      }

      if !rowIDs.isEmpty && conversationInvalidationCount >= 1 {
        return (rowIDs, conversationInvalidationCount)
      }
    }

    return (rowIDs, conversationInvalidationCount)
  }
}

func makeUserRowEntry(
  sessionId: String,
  rowId: String,
  sequence: UInt64,
  content: String
) -> ServerConversationRowEntry {
  ServerConversationRowEntry(
    sessionId: sessionId,
    sequence: sequence,
    turnId: "turn-\(sequence)",
    row: .user(
      ServerConversationMessageRow(
        id: rowId,
        content: content,
        turnId: "turn-\(sequence)"
      )
    )
  )
}

func makeAssistantRowEntry(
  sessionId: String,
  rowId: String,
  sequence: UInt64,
  content: String
) -> ServerConversationRowEntry {
  ServerConversationRowEntry(
    sessionId: sessionId,
    sequence: sequence,
    turnId: "turn-\(sequence)",
    row: .assistant(
      ServerConversationMessageRow(
        id: rowId,
        content: content,
        turnId: "turn-\(sequence)"
      )
    )
  )
}
