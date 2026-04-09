import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionStoreLocalConversationNamingTests {
  @Test func sendMessageSetsSummaryFromAuthoritativeFirstPromptOnlyOnce() async throws {
    let fixture = LocalNamingHTTPFixture(
      sessionState: makeSessionStateObject(
        firstPrompt: "Investigate Apple Foundation title resets"
      ),
      generatedTitle: "Fix Apple Session Titles"
    )
    let store = try makeStore(loader: { request in try await fixture.loader(request) })
    store._localNamingAvailabilityOverride = .available
    store._localTitleGenerator = { context in
      await fixture.generateTitle(for: context)
    }

    try await store.sendMessage(
      sessionId: "session-1",
      content: "Investigate Apple Foundation title resets"
    )
    await fixture.waitForSummaryRequestCount(1)

    try await store.sendMessage(
      sessionId: "session-1",
      content: "Give me a progress update"
    )

    #expect(await fixture.sendMessageRequestCount == 2)
    #expect(await fixture.detailRequestCount == 1)
    #expect(await fixture.generatedContextCount == 1)
    #expect(await fixture.summaryRequestCount == 1)
    #expect(await fixture.lastSummary == "Fix Apple Session Titles")

    let contexts = await fixture.generatedContexts
    #expect(contexts.count == 1)
    #expect(contexts.first?.firstPrompt == "Investigate Apple Foundation title resets")
    #expect(contexts.first?.projectName == "OrbitDock")
    #expect(contexts.first?.projectLeaf == "project")
  }

  @Test func sendMessageSkipsLocalNamingWhenSessionAlreadyHasSummary() async throws {
    let fixture = LocalNamingHTTPFixture(
      sessionState: makeSessionStateObject(
        summary: "Existing Session Title",
        firstPrompt: "Investigate Apple Foundation title resets"
      ),
      generatedTitle: "Should Not Be Used"
    )
    let store = try makeStore(loader: { request in try await fixture.loader(request) })
    store._localNamingAvailabilityOverride = .available
    store._localTitleGenerator = { context in
      await fixture.generateTitle(for: context)
    }

    try await store.sendMessage(
      sessionId: "session-1",
      content: "Investigate Apple Foundation title resets"
    )
    await fixture.waitForDetailRequestCount(1)

    #expect(await fixture.sendMessageRequestCount == 1)
    #expect(await fixture.detailRequestCount == 1)
    #expect(await fixture.generatedContextCount == 0)
    #expect(await fixture.summaryRequestCount == 0)
  }

  @Test func sendMessageSkipsLocalNamingForLaterPromptMismatch() async throws {
    let fixture = LocalNamingHTTPFixture(
      sessionState: makeSessionStateObject(
        firstPrompt: "Investigate Apple Foundation title resets"
      ),
      generatedTitle: "Should Not Be Used"
    )
    let store = try makeStore(loader: { request in try await fixture.loader(request) })
    store._localNamingAvailabilityOverride = .available
    store._localTitleGenerator = { context in
      await fixture.generateTitle(for: context)
    }

    try await store.sendMessage(
      sessionId: "session-1",
      content: "Give me a progress update"
    )
    await fixture.waitForDetailRequestCount(1)

    #expect(await fixture.sendMessageRequestCount == 1)
    #expect(await fixture.detailRequestCount == 1)
    #expect(await fixture.generatedContextCount == 0)
    #expect(await fixture.summaryRequestCount == 0)
  }

  @Test func plannerUsesProjectContextAndRejectsPromptMismatch() {
    let decision = LocalConversationNamingPlanner.decision(
      prompt: "Give me a progress update",
      sessionState: LocalConversationNamingSessionState(
        firstPrompt: "Investigate Apple Foundation title resets",
        projectName: "OrbitDock",
        projectPath: "/tmp/project"
      )
    )

    #expect(decision == .skip(claimSession: true))
  }

  private func makeStore(loader: @escaping ServerClients.DataLoader) throws -> SessionStore {
    let baseURL = try #require(URL(string: "http://127.0.0.1:4000"))
    let clients = ServerClients(serverURL: baseURL, authToken: nil, dataLoader: loader)
    return SessionStore(
      clients: clients,
      connection: SessionStoreConnectionSpy(),
      endpointId: UUID()
    )
  }

  private func makeSessionStateObject(
    customName: String? = nil,
    summary: String? = nil,
    firstPrompt: String? = nil,
    projectName: String? = "OrbitDock",
    projectPath: String = "/tmp/project"
  ) -> [String: Any] {
    [
      "id": "session-1",
      "provider": "claude",
      "project_path": projectPath,
      "transcript_path": NSNull(),
      "project_name": projectName ?? (NSNull() as Any),
      "model": NSNull(),
      "custom_name": customName ?? (NSNull() as Any),
      "summary": summary ?? (NSNull() as Any),
      "status": "active",
      "work_status": "waiting",
      "control_mode": "direct",
      "lifecycle_state": "open",
      "accepts_user_input": true,
      "steerable": false,
      "rows": [],
      "total_row_count": 0,
      "has_more_before": false,
      "oldest_sequence": NSNull(),
      "newest_sequence": NSNull(),
      "pending_approval": NSNull(),
      "token_usage": [
        "input_tokens": 0,
        "output_tokens": 0,
        "cached_tokens": 0,
        "context_window": 0,
      ],
      "token_usage_snapshot_kind": "unknown",
      "current_diff": NSNull(),
      "cumulative_diff": NSNull(),
      "current_plan": NSNull(),
      "codex_integration_mode": NSNull(),
      "claude_integration_mode": "direct",
      "approval_policy": NSNull(),
      "approval_policy_details": NSNull(),
      "sandbox_mode": NSNull(),
      "sandbox_policy_details": NSNull(),
      "permission_mode": NSNull(),
      "allow_bypass_permissions": false,
      "collaboration_mode": NSNull(),
      "multi_agent": NSNull(),
      "personality": NSNull(),
      "service_tier": NSNull(),
      "developer_instructions": NSNull(),
      "codex_config_source": NSNull(),
      "codex_config_mode": NSNull(),
      "codex_config_profile": NSNull(),
      "codex_model_provider": NSNull(),
      "codex_config_overrides": NSNull(),
      "pending_tool_name": NSNull(),
      "pending_tool_input": NSNull(),
      "pending_question": NSNull(),
      "pending_approval_id": NSNull(),
      "started_at": NSNull(),
      "last_activity_at": NSNull(),
      "forked_from_session_id": NSNull(),
      "revision": 1,
      "current_turn_id": NSNull(),
      "turn_count": 0,
      "turn_diffs": [],
      "git_branch": NSNull(),
      "git_sha": NSNull(),
      "current_cwd": NSNull(),
      "first_prompt": firstPrompt ?? (NSNull() as Any),
      "last_message": NSNull(),
      "subagents": [],
      "effort": NSNull(),
      "terminal_session_id": NSNull(),
      "terminal_app": NSNull(),
      "approval_version": 0,
      "repository_root": NSNull(),
      "is_worktree": false,
      "worktree_id": NSNull(),
      "unread_count": 0,
      "mission_id": NSNull(),
      "issue_identifier": NSNull(),
    ]
  }

}

private actor LocalNamingHTTPFixture {
  private let sessionState: [String: Any]
  private let generatedTitle: String?
  private var detailWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var summaryWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

  private(set) var sendMessageRequestCount = 0
  private(set) var detailRequestCount = 0
  private(set) var summaryRequestCount = 0
  private(set) var lastSummary: String?
  private(set) var generatedContexts: [LocalConversationNamingContext] = []

  init(sessionState: [String: Any], generatedTitle: String?) {
    self.sessionState = sessionState
    self.generatedTitle = generatedTitle
  }

  var generatedContextCount: Int {
    generatedContexts.count
  }

  func waitForDetailRequestCount(_ target: Int) async {
    guard detailRequestCount < target else { return }
    await withCheckedContinuation { continuation in
      detailWaiters[target, default: []].append(continuation)
    }
  }

  func waitForSummaryRequestCount(_ target: Int) async {
    guard summaryRequestCount < target else { return }
    await withCheckedContinuation { continuation in
      summaryWaiters[target, default: []].append(continuation)
    }
  }

  func generateTitle(for context: LocalConversationNamingContext) -> String? {
    generatedContexts.append(context)
    return generatedTitle
  }

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    let method = request.httpMethod ?? "GET"
    let path = url.path

    switch (method, path) {
      case ("POST", "/api/sessions/session-1/messages"):
        sendMessageRequestCount += 1
        let object = [
          "accepted": true,
          "row": [
            "session_id": "session-1",
            "sequence": 1,
            "turn_id": "turn-1",
            "row": [
              "row_type": "user",
              "id": "send-row-1",
              "content": "hello from send",
              "is_streaming": false,
            ],
          ],
        ] as [String: Any]
        return try makeHTTPResponse(for: url, object: object)

      case ("GET", "/api/sessions/session-1/detail"):
        detailRequestCount += 1
        resumeWaiters(in: &detailWaiters, reached: detailRequestCount)
        return try makeHTTPResponse(
          for: url,
          object: [
            "revision": 1,
            "session": sessionState,
          ]
        )

      case ("PATCH", "/api/sessions/session-1/summary"):
        summaryRequestCount += 1
        resumeWaiters(in: &summaryWaiters, reached: summaryRequestCount)
        if let data = request.httpBody,
           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          lastSummary = json["summary"] as? String
        }
        return try makeHTTPResponse(for: url, object: ["accepted": true])

      default:
        Issue.record("Unhandled request: \(method) \(path)")
        return try makeHTTPResponse(for: url, object: ["accepted": true])
    }
  }

  private func makeHTTPResponse(for url: URL, object: Any) throws -> (Data, URLResponse) {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
    return (data, response)
  }

  private func resumeWaiters(
    in waiters: inout [Int: [CheckedContinuation<Void, Never>]],
    reached count: Int
  ) {
    let readyTargets = waiters.keys.filter { $0 <= count }
    for target in readyTargets {
      let continuations = waiters.removeValue(forKey: target) ?? []
      continuations.forEach { $0.resume() }
    }
  }
}
