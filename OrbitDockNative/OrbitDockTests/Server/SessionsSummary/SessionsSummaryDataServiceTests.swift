import Foundation
@testable import OrbitDock
import Testing

@Suite(.serialized)
@MainActor
struct SessionsSummaryDataServiceTests {
  @Test func sessionsSummaryRefreshUsesCompactEndpointAndDedupesTrackedSessions() async throws {
    let fixture = SessionsSummaryLoaderFixture(
      responses: [
        .snapshot(
          revision: 1,
          activeTitle: "Active One",
          recentTitles: ["Active One", "Recent One"]
        ),
      ]
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = SessionsSummaryDataService()
    defer { service.stop() }

    service.start(runtimeRegistry: harness.registry)
    await service.refreshNow()

    #expect(service.activeSessions.map(\.displayTitle) == ["Active One"])
    #expect(service.recentSessions.map(\.displayTitle) == ["Recent One"])
    #expect(service.counts.active == 1)
    #expect(service.summaryRevision > 0)
    #expect(Set(service.compactSessions().map(\.displayTitle)) == ["Active One", "Recent One"])
    let requestPaths = await fixture.requestPaths()
    #expect(!requestPaths.isEmpty)
    #expect(requestPaths.allSatisfy { $0 == "/api/sessions/summary" })
  }

  @Test func sessionsSummaryIgnoresArchivedSessionsInvalidationAndRefreshesOnSessionsSummaryInvalidation() async throws {
    let fixture = SessionsSummaryLoaderFixture(
      responses: [
        .snapshot(revision: 1, activeTitle: "Initial Active", recentTitles: ["Recent One"]),
        .snapshot(revision: 2, activeTitle: "Updated Active", recentTitles: ["Recent Two"]),
      ]
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = SessionsSummaryDataService()
    defer { service.stop() }

    service.start(runtimeRegistry: harness.registry)
    await fixture.waitForRequestCount(1)
    await drainMainActorTasks()

    harness.connection.emitForTesting(.archivedSessionsInvalidated(revision: 2))
    await drainMainActorTasks()
    #expect(await fixture.requestPaths() == ["/api/sessions/summary"])

    harness.connection.emitForTesting(.sessionsSummaryInvalidated(revision: 2))
    await fixture.waitForRequestCount(2)
    await drainMainActorTasks()

    #expect(service.activeSessions.map(\.displayTitle) == ["Updated Active"])
    #expect(service.recentSessions.map(\.displayTitle) == ["Recent Two"])
    #expect(service.summaryRevision > 0)
    #expect(await fixture.requestPaths() == ["/api/sessions/summary", "/api/sessions/summary"])
  }

  @Test func repeatedSummaryInvalidationsDuringInflightRefreshCoalesceIntoOneFollowupRefresh() async throws {
    let fixture = SessionsSummaryLoaderFixture(
      responses: [
        .snapshot(revision: 1, activeTitle: "Initial Active", recentTitles: ["Recent One"]),
        .snapshot(revision: 2, activeTitle: "Updated Active", recentTitles: ["Recent Two"]),
      ],
      pauseFirstRequest: true
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = SessionsSummaryDataService()
    defer { service.stop() }

    service.start(runtimeRegistry: harness.registry)
    await fixture.waitForRequestCount(1)

    harness.connection.emitForTesting(.sessionsSummaryInvalidated(revision: 2))
    harness.connection.emitForTesting(.sessionsSummaryInvalidated(revision: 2))
    await fixture.resumeFirstResponse()
    await fixture.waitForRequestCount(2)
    await drainMainActorTasks()

    #expect(service.activeSessions.map(\.displayTitle) == ["Updated Active"])
    #expect(service.recentSessions.map(\.displayTitle) == ["Recent Two"])
    #expect(await fixture.requestPaths() == ["/api/sessions/summary", "/api/sessions/summary"])
  }

  @Test func stopUnsubscribesSessionsSummaryStream() async {
    let fixture = SessionsSummaryLoaderFixture(
      responses: [.snapshot(revision: 1, activeTitle: "Active One", recentTitles: [])]
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = SessionsSummaryDataService()

    service.start(runtimeRegistry: harness.registry)
    harness.connection.emitForTesting(.connectionStatusChanged(.connected))
    await drainMainActorTasks()
    #expect(harness.connection.hasSubscribedSessionsSummaryStream)

    service.stop()

    #expect(harness.connection.hasSubscribedSessionsSummaryStream == false)
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

private actor SessionsSummaryLoaderFixture {
  enum Response {
    case snapshot(revision: UInt64, activeTitle: String, recentTitles: [String])
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
    guard url.path == "/api/sessions/summary" else {
      throw URLError(.badURL)
    }

    if pauseFirstRequest && !hasPausedFirstRequest {
      hasPausedFirstRequest = true
      await withCheckedContinuation { continuation in
        firstResponseContinuation = continuation
      }
    }

    let response = queuedResponses.isEmpty
      ? .snapshot(revision: 1, activeTitle: "Fallback Active", recentTitles: [])
      : queuedResponses.removeFirst()
    let body: Data
    switch response {
      case let .snapshot(revision, activeTitle, recentTitles):
        body = responseBody(
          revision: revision,
          activeTitle: activeTitle,
          recentTitles: recentTitles
        )
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

  private func responseBody(
    revision: UInt64,
    activeTitle: String,
    recentTitles: [String]
  ) -> Data {
    let recentSessions = recentTitles.enumerated().map { index, title in
      sessionJSON(
        sessionId: index == 0 && title == activeTitle ? "session-active" : "session-recent-\(index)",
        title: title,
        status: "ended",
        workStatus: "ended",
        listStatus: "ended",
        lastActivityAt: "2026-04-14T12:0\(index + 2):00Z"
      )
    }.joined(separator: ",")

    return Data(
      """
      {
        "revision": \(revision),
        "counts": {
          "total": \(max(recentTitles.count + 1, 1)),
          "active": 1,
          "working": 1,
          "attention": 0,
          "ready": 0
        },
        "active_sessions": [
          \(sessionJSON(
            sessionId: "session-active",
            title: activeTitle,
            status: "active",
            workStatus: "working",
            listStatus: "working",
            lastActivityAt: "2026-04-14T12:01:00Z"
          ))
        ],
        "recent_sessions": [
          \(recentSessions)
        ]
      }
      """.utf8
    )
  }

  private func sessionJSON(
    sessionId: String,
    title: String,
    status: String,
    workStatus: String,
    listStatus: String,
    lastActivityAt: String
  ) -> String {
    """
    {
      "id": "\(sessionId)",
      "provider": "codex",
      "project_path": "/tmp/project",
      "project_name": "Project",
      "git_branch": "main",
      "model": "gpt-5",
      "status": "\(status)",
      "work_status": "\(workStatus)",
      "control_mode": "direct",
      "lifecycle_state": "\(status == "active" ? "open" : "ended")",
      "steerable": true,
      "codex_integration_mode": "direct",
      "claude_integration_mode": null,
      "started_at": "2026-04-14T12:00:00Z",
      "last_activity_at": "\(lastActivityAt)",
      "unread_count": 0,
      "has_turn_diff": false,
      "pending_tool_name": null,
      "repository_root": "/tmp/project",
      "is_worktree": false,
      "worktree_id": null,
      "total_tokens": 0,
      "total_cost_usd": 0,
      "input_tokens": 0,
      "output_tokens": 0,
      "cached_tokens": 0,
      "display_title": "\(title)",
      "display_title_sort_key": "\(title.lowercased())",
      "display_search_text": "\(title)",
      "context_line": "Context",
      "list_status": "\(listStatus)",
      "summary_revision": 1,
      "effort": null,
      "active_worker_count": 0,
      "pending_tool_family": null,
      "forked_from_session_id": null,
      "mission_id": null,
      "issue_identifier": null
    }
    """
  }
}
