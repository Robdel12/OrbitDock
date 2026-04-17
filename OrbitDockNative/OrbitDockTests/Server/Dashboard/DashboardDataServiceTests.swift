import Foundation
@testable import OrbitDock
import Testing

@Suite(.serialized)
@MainActor
struct DashboardDataServiceTests {
  @Test func activeSessionsInvalidationTriggersRefetchOfActiveSessionsSnapshot() async throws {
    let fixture = DashboardLoaderFixture(
      responses: [
        .snapshot(revision: 1, title: "Initial Title"),
        .snapshot(revision: 2, title: "Updated Title"),
      ]
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = DashboardDataService()
    defer { service.stop() }

    service.start(runtimeRegistry: harness.registry)
    await fixture.waitForRequestCount(1)
    await drainMainActorTasks()

    #expect(service.snapshot?.conversations.map(\.title) == ["Initial Title"])
    #expect(service.snapshot?.revision == 1)
    #expect(await fixture.requestPaths() == ["/api/sessions/active"])

    harness.connection.emitForTesting(.activeSessionsInvalidated(revision: 2))
    await fixture.waitForRequestCount(2)
    await drainMainActorTasks()

    #expect(service.snapshot?.conversations.map(\.title) == ["Updated Title"])
    #expect(service.snapshot?.revision == 2)
    #expect(await fixture.requestPaths() == ["/api/sessions/active", "/api/sessions/active"])
  }

  @Test func activeSessionsInvalidationRefetchesDashboardSnapshot() async throws {
    let fixture = DashboardLoaderFixture(
      responses: [
        .snapshot(revision: 1, title: "Initial Title"),
        .snapshot(revision: 2, title: "Refetched Title"),
      ]
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = DashboardDataService()
    defer { service.stop() }

    service.start(runtimeRegistry: harness.registry)
    await fixture.waitForRequestCount(1)
    await drainMainActorTasks()

    harness.connection.emitForTesting(.activeSessionsInvalidated(revision: 2))
    await fixture.waitForRequestCount(2)
    await drainMainActorTasks()

    #expect(service.snapshot?.conversations.map(\.title) == ["Refetched Title"])
    #expect(service.snapshot?.revision == 2)
    #expect(await fixture.requestPaths() == ["/api/sessions/active", "/api/sessions/active"])
  }

  @Test func repeatedInvalidationsDuringInflightRefreshCoalesceIntoOneFollowupRefresh() async throws {
    let fixture = DashboardLoaderFixture(
      responses: [
        .snapshot(revision: 1, title: "Initial Title"),
        .snapshot(revision: 2, title: "Updated Title"),
      ],
      pauseFirstRequest: true
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = DashboardDataService()
    defer { service.stop() }

    service.start(runtimeRegistry: harness.registry)
    await fixture.waitForRequestCount(1)

    harness.connection.emitForTesting(.activeSessionsInvalidated(revision: 2))
    harness.connection.emitForTesting(.activeSessionsInvalidated(revision: 2))
    await fixture.resumeFirstResponse()
    await fixture.waitForRequestCount(2)
    await drainMainActorTasks()

    #expect(service.snapshot?.conversations.map(\.title) == ["Updated Title"])
    #expect(await fixture.requestPaths() == ["/api/sessions/active", "/api/sessions/active"])
  }

  @Test func stopUnsubscribesActiveSessionsStream() async {
    let fixture = DashboardLoaderFixture(
      responses: [.snapshot(revision: 1, title: "Initial Title")]
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = DashboardDataService()

    service.start(runtimeRegistry: harness.registry)
    harness.connection.emitForTesting(.connectionStatusChanged(.connected))
    await drainMainActorTasks()
    #expect(harness.connection.hasSubscribedActiveSessionsStream)

    service.stop()

    #expect(harness.connection.hasSubscribedActiveSessionsStream == false)
  }

  private func makeHarness(
    loader: @escaping ServerClients.DataLoader
  ) -> (registry: ServerRuntimeRegistry, connection: ServerConnection) {
    let endpoint = ServerEndpoint(
      name: "Primary",
      wsURL: URL(string: "ws://127.0.0.1:3000/ws")!
    )
    let connection = ServerConnection(authToken: nil)
    let clients = ServerClients(
      serverURL: URL(string: "http://127.0.0.1:3000")!,
      authToken: nil,
      dataLoader: loader
    )
    let runtime = ServerRuntime(
      endpoint: endpoint,
      clients: clients,
      connection: connection
    )
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { _ in runtime },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)
    return (registry, connection)
  }

  private func drainMainActorTasks(iterations: Int = 20) async {
    for _ in 0..<iterations {
      await Task.yield()
    }
  }

}

private actor DashboardLoaderFixture {
  enum Response {
    case snapshot(revision: UInt64, title: String)
  }

  private var queuedResponses: [Response]
  private let pauseFirstRequest: Bool
  private var paths: [String] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var firstResponseContinuation: CheckedContinuation<Void, Never>?
  private var hasPausedFirstRequest = false

  init(
    responses: [Response],
    pauseFirstRequest: Bool = false
  ) {
    queuedResponses = responses
    self.pauseFirstRequest = pauseFirstRequest
  }

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    paths.append(url.path)
    flushWaiters()
    guard url.path == "/api/sessions/active" else {
      throw URLError(.badURL)
    }

    if pauseFirstRequest && !hasPausedFirstRequest {
      hasPausedFirstRequest = true
      await withCheckedContinuation { continuation in
        firstResponseContinuation = continuation
      }
    }

    let response = queuedResponses.isEmpty ? .snapshot(revision: 1, title: "Fallback Title") : queuedResponses.removeFirst()
    let body: Data
    switch response {
      case let .snapshot(revision, title):
        body = responseBody(revision: revision, title: title)
    }

    let httpResponse = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "application/json",
        "X-OrbitDock-Server-Version": "0.9.0",
        "X-OrbitDock-Minimum-Client-Version": "0.4.0",
      ]
    )!
    return (body, httpResponse)
  }

  func requestPaths() -> [String] {
    paths
  }

  func waitForRequestCount(_ count: Int) async {
    if paths.count >= count { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append((count, continuation))
    }
  }

  func resumeFirstResponse() {
    firstResponseContinuation?.resume()
    firstResponseContinuation = nil
  }

  private func flushWaiters() {
    var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
    for (count, continuation) in requestWaiters {
      if paths.count >= count {
        continuation.resume()
      } else {
        remaining.append((count, continuation))
      }
    }
    requestWaiters = remaining
  }

  private func responseBody(revision: UInt64, title: String) -> Data {
    Data(
      """
      {
        "revision": \(revision),
        "conversations": [
          {
            "session_id": "session-1",
            "provider": "codex",
            "project_path": "/tmp/project",
            "grouping_path": "/tmp/project",
            "grouping_name": "Project",
            "project_name": "Project",
            "repository_root": "/tmp/project",
            "git_branch": "main",
            "is_worktree": false,
            "worktree_id": null,
            "model": "gpt-5",
            "codex_integration_mode": "direct",
            "claude_integration_mode": null,
            "status": "active",
            "work_status": "working",
            "control_mode": "direct",
            "lifecycle_state": "open",
            "list_status": "working",
            "display_title": "\(title)",
            "context_line": "Context",
            "last_message": "Message",
            "preview_text": "Preview",
            "activity_summary": "Working",
            "alert_context": null,
            "started_at": "2026-04-14T12:00:00Z",
            "last_activity_at": "2026-04-14T12:01:00Z",
            "unread_count": 0,
            "has_turn_diff": false,
            "diff_preview": null,
            "pending_tool_name": null,
            "pending_tool_input": null,
            "pending_question": null,
            "tool_count": 0,
            "active_worker_count": 0,
            "issue_identifier": null,
            "effort": null
          }
        ],
        "counts": {
          "attention": 0,
          "running": 1,
          "ready": 0,
          "direct": 1
        },
        "project_groups": []
      }
      """.utf8
    )
  }
}
