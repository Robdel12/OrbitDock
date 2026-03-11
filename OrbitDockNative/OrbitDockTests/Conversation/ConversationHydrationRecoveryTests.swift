import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ConversationHydrationRecoveryTests {
  private let endpointId = UUID()

  @Test func coherentRecentBootstrapStopsAtRecentWindow() async throws {
    let transport = ConversationRecoveryTransport()
    let store = ConversationStore(
      sessionId: "session-recovery",
      endpointId: endpointId,
      clients: ServerClients(
        serverURL: URL(string: "http://127.0.0.1:4000")!,
        authToken: nil,
        dataLoader: transport.load
      )
    )

    let revision = await store.bootstrap(goal: ConversationRecoveryGoal.coherentRecent)

    #expect(revision == 99)
    #expect(store.messages.map(\TranscriptMessage.id) == [
      "user-5", "assistant-6", "user-7", "assistant-8",
      "user-9", "assistant-10", "user-11", "assistant-12",
    ])
    #expect(store.totalMessageCount == 12)
    #expect(store.hydrationState == ConversationHydrationState.readyComplete)
    #expect(store.hasMoreHistoryBefore)
    #expect(await transport.requestPaths() == ["/api/sessions/session-recovery/conversation?limit=50"])
  }

  @Test func completeHistoryBootstrapRecoversOlderMessagesMissedWhileAway() async throws {
    let transport = ConversationRecoveryTransport()
    let store = ConversationStore(
      sessionId: "session-recovery",
      endpointId: endpointId,
      clients: ServerClients(
        serverURL: URL(string: "http://127.0.0.1:4000")!,
        authToken: nil,
        dataLoader: transport.load
      )
    )

    let revision = await store.bootstrap(goal: ConversationRecoveryGoal.completeHistory)
    await store.waitForHydrationToSettle()

    #expect(revision == 99)
    #expect(store.messages.map(\TranscriptMessage.id) == [
      "user-1", "tool-2", "assistant-3", "user-4",
      "user-5", "assistant-6", "user-7", "assistant-8",
      "user-9", "assistant-10", "user-11", "assistant-12",
    ])
    #expect(store.totalMessageCount == 12)
    #expect(store.oldestLoadedSequence == 1)
    #expect(store.newestLoadedSequence == 12)
    #expect(store.hydrationState == ConversationHydrationState.readyComplete)
    #expect(store.hasMoreHistoryBefore == false)
    let paths = await transport.requestPaths()
    #expect(paths.count == 2)
    #expect(paths.contains("/api/sessions/session-recovery/conversation?limit=50"))
    #expect(paths.contains("/api/sessions/session-recovery/messages?before_sequence=5&limit=50"))
  }

  @Test func cachedConversationStaysRenderableWhileAuthoritativeRecoveryIsStillNeeded() {
    let store = ConversationStore(
      sessionId: "session-cache",
      endpointId: endpointId,
      clients: ServerClients(
        serverURL: URL(string: "http://127.0.0.1:4000")!,
        authToken: nil,
        dataLoader: { _ in throw ServerRequestError.notConnected }
      )
    )

    store.restoreFromCache(
      CachedConversation(
        messages: [
          makeMessage(id: "assistant-10", sequence: 10, type: .assistant, content: "Recent reply")
        ],
        totalMessageCount: 12,
        oldestSequence: 10,
        newestSequence: 10,
        hasMoreHistoryBefore: true,
        cachedAt: Date()
      )
    )

    #expect(store.hasRenderableConversation)
    #expect(store.hydrationState == ConversationHydrationState.readyPartial)
    #expect(store.isFullyHydrated == false)
  }

  @Test func sessionReopenRestoresCachedConversationThenRecoversMissedHistory() async throws {
    let transport = ConversationRecoveryTransport()
    let store = SessionStore(
      clients: ServerClients(
        serverURL: URL(string: "http://127.0.0.1:4000")!,
        authToken: nil,
        dataLoader: transport.load
      ),
      eventStream: EventStream(authToken: nil),
      endpointId: UUID()
    )
    let sessionId = "session-cache"

    store.conversation(sessionId).restoreFromCache(
      CachedConversation(
        messages: [
          makeMessage(id: "assistant-10", sequence: 10, type: .assistant, content: "Recent reply"),
          makeMessage(id: "tool-11", sequence: 11, type: .tool, content: "Recent tool output"),
        ],
        totalMessageCount: 12,
        oldestSequence: 10,
        newestSequence: 11,
        hasMoreHistoryBefore: true,
        cachedAt: Date()
      )
    )

    store.unsubscribeFromSession(sessionId)
    #expect(store.conversation(sessionId).messages.isEmpty)

    store.subscribeToSession(
      sessionId,
      forceRefresh: false,
      recoveryGoal: ConversationRecoveryGoal.completeHistory
    )

    let conversation = store.conversation(sessionId)
    try await waitUntil("cached conversation restored immediately on reopen") {
      conversation.messages.map(\TranscriptMessage.id) == ["assistant-10", "tool-11"]
        && conversation.hasMoreHistoryBefore
        && conversation.totalMessageCount == 12
    }

    try await waitUntil("authoritative bootstrap kicked off") {
      await transport.requestPaths().contains("/api/sessions/session-cache/conversation?limit=50")
    }

    await conversation.waitForHydrationToSettle()

    #expect(conversation.messages.map(\TranscriptMessage.id) == [
      "user-7", "assistant-8", "tool-9", "assistant-10", "tool-11", "assistant-12",
    ])
    #expect(conversation.hasMoreHistoryBefore == false)
    #expect(conversation.totalMessageCount == 6)
    #expect(conversation.hydrationState == ConversationHydrationState.readyComplete)
    #expect(store.session(sessionId).approvalHistory.isEmpty)

    let paths = await transport.requestPaths()
    #expect(paths.count == 4)
    #expect(paths.contains("/api/sessions/session-cache"))
    #expect(paths.contains("/api/sessions/session-cache/conversation?limit=50"))
    #expect(paths.contains("/api/approvals?limit=200&session_id=session-cache"))
    #expect(paths.contains("/api/sessions/session-cache/messages?before_sequence=10&limit=50"))
  }

  @Test func partialSnapshotDoesNotStompRecoveredHistory() async throws {
    let transport = ConversationRecoveryTransport()
    let store = ConversationStore(
      sessionId: "session-recovery",
      endpointId: endpointId,
      clients: ServerClients(
        serverURL: URL(string: "http://127.0.0.1:4000")!,
        authToken: nil,
        dataLoader: transport.load
      )
    )

    _ = await store.bootstrap(goal: ConversationRecoveryGoal.completeHistory)
    await store.waitForHydrationToSettle()

    #expect(store.messages.map(\TranscriptMessage.id) == [
      "user-1", "tool-2", "assistant-3", "user-4",
      "user-5", "assistant-6", "user-7", "assistant-8",
      "user-9", "assistant-10", "user-11", "assistant-12",
    ])

    store.handleSnapshot(
      makeSnapshot(
        sessionId: "session-recovery",
        messages: [
          makeServerMessage(id: "user-9", sequence: 9, type: .user, content: "Ninth prompt"),
          makeServerMessage(id: "assistant-10", sequence: 10, type: .assistant, content: "Tenth reply"),
          makeServerMessage(id: "user-11", sequence: 11, type: .user, content: "Eleventh prompt"),
          makeServerMessage(id: "assistant-12", sequence: 12, type: .assistant, content: "Twelfth reply"),
        ],
        totalMessageCount: 12,
        hasMoreBefore: true,
        oldestSequence: 9,
        newestSequence: 12
      )
    )

    #expect(store.messages.map(\TranscriptMessage.id) == [
      "user-1", "tool-2", "assistant-3", "user-4",
      "user-5", "assistant-6", "user-7", "assistant-8",
      "user-9", "assistant-10", "user-11", "assistant-12",
    ])
    #expect(store.oldestLoadedSequence == 1)
    #expect(store.newestLoadedSequence == 12)
    #expect(store.hasMoreHistoryBefore)
    #expect(store.hydrationState == ConversationHydrationState.readyPartial)
  }

  private func makeMessage(
    id: String,
    sequence: UInt64,
    type: TranscriptMessage.MessageType,
    content: String
  ) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: sequence,
      type: type,
      content: content,
      timestamp: Date(timeIntervalSince1970: TimeInterval(sequence))
    )
  }

  private func makeSnapshot(
    sessionId: String,
    messages: [ServerMessage],
    totalMessageCount: UInt64,
    hasMoreBefore: Bool,
    oldestSequence: UInt64?,
    newestSequence: UInt64?
  ) -> ServerSessionState {
    let encodedMessages = messages.map { message in
      """
      {
        "id": "\(message.id)",
        "session_id": "\(message.sessionId)",
        "sequence": \(message.sequence ?? 0),
        "message_type": "\(message.type.rawValue)",
        "content": \(message.content.debugDescription),
        "tool_name": \(jsonStringOrNull(message.toolName)),
        "tool_output": \(jsonStringOrNull(message.toolOutput)),
        "is_error": \(message.isError ? "true" : "false"),
        "is_in_progress": \(message.isInProgress ? "true" : "false"),
        "timestamp": "\(message.timestamp)"
      }
      """
    }.joined(separator: ",")

    let json = """
    {
      "id": "\(sessionId)",
      "provider": "codex",
      "project_path": "/tmp/project",
      "status": "active",
      "work_status": "working",
      "messages": [\(encodedMessages)],
      "total_message_count": \(totalMessageCount),
      "has_more_before": \(hasMoreBefore ? "true" : "false"),
      "oldest_sequence": \(oldestSequence ?? 0),
      "newest_sequence": \(newestSequence ?? 0),
      "token_usage": {"input_tokens":0,"output_tokens":0,"cached_tokens":0,"context_window":0},
      "token_usage_snapshot_kind": "unknown",
      "codex_integration_mode": "direct",
      "turn_count": 0,
      "turn_diffs": [],
      "subagents": [],
      "revision": 100
    }
    """

    let decoder = JSONDecoder()
    return try! decoder.decode(ServerSessionState.self, from: Data(json.utf8))
  }

  private func makeServerMessage(
    id: String,
    sequence: UInt64,
    type: ServerMessageType,
    content: String
  ) -> ServerMessage {
    let json = """
    {
      "id": "\(id)",
      "session_id": "session-recovery",
      "sequence": \(sequence),
      "message_type": "\(type.rawValue)",
      "content": \(content.debugDescription),
      "is_error": false,
      "timestamp": "2026-03-09T10:00:\(String(format: "%02d", sequence))Z"
    }
    """

    let decoder = JSONDecoder()
    return try! decoder.decode(ServerMessage.self, from: Data(json.utf8))
  }

  private func jsonStringOrNull(_ value: String?) -> String {
    guard let value else { return "null" }
    return value.debugDescription
  }
}

private actor ConversationRecoveryTransport {
  private var paths: [String] = []

  func requestPaths() -> [String] {
    paths
  }

  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    let recordedPath = pathWithSortedQuery(url)
    paths.append(recordedPath)

    let json: String
    switch (url.path, queryItems(url)) {
      case ("/api/sessions/session-cache", _):
        json = """
        {
          "session": {
            "id": "session-cache",
            "provider": "codex",
            "project_path": "/tmp/project",
            "status": "active",
            "work_status": "working",
            "messages": [],
            "total_message_count": 6,
            "has_more_before": true,
            "oldest_sequence": 10,
            "newest_sequence": 12,
            "token_usage": {"input_tokens":0,"output_tokens":0,"cached_tokens":0,"context_window":0},
            "token_usage_snapshot_kind": "unknown",
            "turn_count": 0,
            "turn_diffs": [],
            "subagents": [],
            "revision": 45
          }
        }
        """
      case ("/api/sessions/session-recovery/conversation", _):
        json = """
        {
          "session": {
            "id": "session-recovery",
            "provider": "codex",
            "project_path": "/tmp/project",
            "status": "active",
            "work_status": "working",
            "messages": [
              {"id":"user-5","session_id":"session-recovery","sequence":5,"message_type":"user","content":"Fifth prompt","is_error":false,"timestamp":"2026-03-09T10:00:05Z"},
              {"id":"assistant-6","session_id":"session-recovery","sequence":6,"message_type":"assistant","content":"Sixth reply","is_error":false,"timestamp":"2026-03-09T10:00:06Z"},
              {"id":"user-7","session_id":"session-recovery","sequence":7,"message_type":"user","content":"Seventh prompt","is_error":false,"timestamp":"2026-03-09T10:00:07Z"},
              {"id":"assistant-8","session_id":"session-recovery","sequence":8,"message_type":"assistant","content":"Eighth reply","is_error":false,"timestamp":"2026-03-09T10:00:08Z"},
              {"id":"user-9","session_id":"session-recovery","sequence":9,"message_type":"user","content":"Ninth prompt","is_error":false,"timestamp":"2026-03-09T10:00:09Z"},
              {"id":"assistant-10","session_id":"session-recovery","sequence":10,"message_type":"assistant","content":"Tenth reply","is_error":false,"timestamp":"2026-03-09T10:00:10Z"},
              {"id":"user-11","session_id":"session-recovery","sequence":11,"message_type":"user","content":"Eleventh prompt","is_error":false,"timestamp":"2026-03-09T10:00:11Z"},
              {"id":"assistant-12","session_id":"session-recovery","sequence":12,"message_type":"assistant","content":"Twelfth reply","is_error":false,"timestamp":"2026-03-09T10:00:12Z"}
            ],
            "total_message_count": 12,
            "has_more_before": true,
            "oldest_sequence": 5,
            "newest_sequence": 12,
            "token_usage": {"input_tokens":0,"output_tokens":0,"cached_tokens":0,"context_window":0},
            "token_usage_snapshot_kind": "unknown",
            "turn_count": 0,
            "turn_diffs": [],
            "subagents": [],
            "revision": 99
          },
          "total_message_count": 12,
          "has_more_before": true,
          "oldest_sequence": 5,
          "newest_sequence": 12
        }
        """
      case ("/api/sessions/session-cache/conversation", _):
        json = """
        {
          "session": {
            "id": "session-cache",
            "provider": "codex",
            "project_path": "/tmp/project",
            "status": "active",
            "work_status": "working",
            "messages": [
              {"id":"assistant-10","session_id":"session-cache","sequence":10,"message_type":"assistant","content":"Recent reply","is_error":false,"timestamp":"2026-03-09T10:00:10Z"},
              {"id":"tool-11","session_id":"session-cache","sequence":11,"message_type":"tool","content":"Recent tool output","tool_name":"bash","tool_output":"ok","is_error":false,"timestamp":"2026-03-09T10:00:11Z"},
              {"id":"assistant-12","session_id":"session-cache","sequence":12,"message_type":"assistant","content":"Newest reply while away","is_error":false,"timestamp":"2026-03-09T10:00:12Z"}
            ],
            "total_message_count": 6,
            "has_more_before": true,
            "oldest_sequence": 10,
            "newest_sequence": 12,
            "token_usage": {"input_tokens":0,"output_tokens":0,"cached_tokens":0,"context_window":0},
            "token_usage_snapshot_kind": "unknown",
            "turn_count": 0,
            "turn_diffs": [],
            "subagents": [],
            "revision": 44
          },
          "total_message_count": 6,
          "has_more_before": true,
          "oldest_sequence": 10,
          "newest_sequence": 12
        }
        """
      case ("/api/sessions/session-recovery/messages", let items)
        where items["before_sequence"] == "5":
        json = """
        {
          "session_id": "session-recovery",
          "messages": [
            {"id":"user-1","session_id":"session-recovery","sequence":1,"message_type":"user","content":"First prompt","is_error":false,"timestamp":"2026-03-09T10:00:01Z"},
            {"id":"tool-2","session_id":"session-recovery","sequence":2,"message_type":"tool","content":"Run migration","tool_name":"bash","tool_output":"ok","is_error":false,"timestamp":"2026-03-09T10:00:02Z"},
            {"id":"assistant-3","session_id":"session-recovery","sequence":3,"message_type":"assistant","content":"Migration complete","is_error":false,"timestamp":"2026-03-09T10:00:03Z"},
            {"id":"user-4","session_id":"session-recovery","sequence":4,"message_type":"user","content":"Continue","is_error":false,"timestamp":"2026-03-09T10:00:04Z"}
          ],
          "total_message_count": 12,
          "has_more_before": false,
          "oldest_sequence": 1,
          "newest_sequence": 4
        }
        """
      case ("/api/sessions/session-recovery/messages", _):
        json = """
        {
          "session_id": "session-recovery",
          "messages": [],
          "total_message_count": 12,
          "has_more_before": false,
          "oldest_sequence": null,
          "newest_sequence": null
        }
        """
      case ("/api/sessions/session-cache/messages", let items)
        where items["before_sequence"] == "10":
        json = """
        {
          "session_id": "session-cache",
          "messages": [
            {"id":"user-7","session_id":"session-cache","sequence":7,"message_type":"user","content":"Do the work while I'm gone","is_error":false,"timestamp":"2026-03-09T10:00:07Z"},
            {"id":"assistant-8","session_id":"session-cache","sequence":8,"message_type":"assistant","content":"Starting now","is_error":false,"timestamp":"2026-03-09T10:00:08Z"},
            {"id":"tool-9","session_id":"session-cache","sequence":9,"message_type":"tool","content":"Ran build","tool_name":"bash","tool_output":"build ok","is_error":false,"timestamp":"2026-03-09T10:00:09Z"}
          ],
          "total_message_count": 6,
          "has_more_before": false,
          "oldest_sequence": 7,
          "newest_sequence": 9
        }
        """
      case ("/api/sessions/session-cache/messages", _):
        json = """
        {
          "session_id": "session-cache",
          "messages": [],
          "total_message_count": 6,
          "has_more_before": false,
          "oldest_sequence": null,
          "newest_sequence": null
        }
        """
      case ("/api/approvals", _):
        json = """
        {
          "session_id": "session-cache",
          "approvals": []
        }
        """
      default:
        Issue.record("Unexpected request path: \(recordedPath)")
        throw ServerRequestError.notConnected
    }

    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(json.utf8), response)
  }

  private func queryItems(_ url: URL) -> [String: String] {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .reduce(into: [:]) { partial, item in
        partial[item.name] = item.value ?? ""
      } ?? [:]
  }

  private func pathWithSortedQuery(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let queryItems = components.queryItems, !queryItems.isEmpty
    else {
      return url.path
    }

    components.queryItems = queryItems.sorted {
      if $0.name == $1.name {
        return ($0.value ?? "") < ($1.value ?? "")
      }
      return $0.name < $1.name
    }

    return components.percentEncodedQuery.map { "\(url.path)?\($0)" } ?? url.path
  }
}

private func waitUntil(
  _ description: String,
  iterations: Int = 200,
  condition: @escaping () async -> Bool
) async throws {
  for _ in 0..<iterations {
    if await condition() {
      return
    }
    await Task.yield()
  }

  Issue.record("Timed out waiting for condition: \(description)")
  throw ServerRequestError.notConnected
}
