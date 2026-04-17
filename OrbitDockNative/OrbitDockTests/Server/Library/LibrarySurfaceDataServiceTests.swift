import Foundation
@testable import OrbitDock
import Testing

@Suite(.serialized)
@MainActor
struct LibraryDataServiceTests {
  @Test func refreshUsesLibraryEndpointAndAppliesLibraryInvalidationWhileLive() async throws {
    let fixture = LibraryLoaderFixture(
      responses: [
        .snapshot(revision: 1, title: "First Title"),
        .snapshot(revision: 2, title: "Updated Title"),
      ]
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = LibraryDataService()
    defer { service.stopLiveUpdates() }

    await service.refreshNow(runtimeRegistry: harness.registry)

    #expect(service.sessions.map(\.displayTitle) == ["First Title"])
    #expect(await fixture.requestPaths() == ["/api/sessions/archive"])

    service.startLiveUpdates(runtimeRegistry: harness.registry)
    harness.connection.emitForTesting(.archivedSessionsInvalidated(revision: 2))
    await fixture.waitForRequestCount(2)
    await drainMainActorTasks()

    #expect(service.sessions.map(\.displayTitle) == ["Updated Title"])
    #expect(await fixture.requestPaths() == ["/api/sessions/archive", "/api/sessions/archive"])
  }

  @Test func liveLibraryUpdatesIgnoreUnrelatedSurfaceInvalidations() async throws {
    let fixture = LibraryLoaderFixture(
      responses: [
        .snapshot(revision: 1, title: "Stable Title"),
      ]
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = LibraryDataService()
    defer { service.stopLiveUpdates() }

    await service.refreshNow(runtimeRegistry: harness.registry)
    service.startLiveUpdates(runtimeRegistry: harness.registry)

    harness.connection.emitForTesting(.activeSessionsInvalidated(revision: 9))
    harness.connection.emitForTesting(.missionsInvalidated(revision: 9))
    await Task.yield()

    #expect(service.sessions.map(\.displayTitle) == ["Stable Title"])
    #expect(await fixture.requestPaths() == ["/api/sessions/archive"])
  }

  @Test func invalidationDuringInflightRefreshQueuesFollowupRefresh() async throws {
    let endpoint = ServerEndpoint(
      name: "Primary",
      wsURL: URL(string: "ws://127.0.0.1:3000/ws")!
    )
    let connection = ServerConnection(authToken: nil)
    let fixture = LibraryLoaderFixture(
      responses: [
        .snapshot(revision: 1, title: "First Title"),
        .snapshot(revision: 2, title: "Second Title"),
      ],
      afterFirstResponse: {
        connection.emitForTesting(.archivedSessionsInvalidated(revision: 2))
      }
    )
    let clients = ServerClients(
      serverURL: URL(string: "http://127.0.0.1:3000")!,
      authToken: nil,
      dataLoader: fixture.loader
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
    let service = LibraryDataService()
    defer { service.stopLiveUpdates() }

    service.startLiveUpdates(runtimeRegistry: registry)
    await service.refreshNow(runtimeRegistry: registry)
    await fixture.waitForRequestCount(2)
    await drainMainActorTasks()

    #expect(await fixture.requestPaths() == ["/api/sessions/archive", "/api/sessions/archive"])
    #expect(service.sessions.map(\.displayTitle) == ["Second Title"])
  }

  @Test func invalidationRefreshPreservesPreviouslyLoadedLibraryPages() async throws {
    let fixture = LibraryLoaderFixture(
      responses: [
        .page(revision: 1, sessionId: "session-1", title: "First Page", nextOffset: 1, totalCount: 2),
        .page(revision: 1, sessionId: "session-2", title: "Second Page", nextOffset: nil, totalCount: 2),
        .page(revision: 2, sessionId: "session-1", title: "First Page Updated", nextOffset: 1, totalCount: 2),
        .page(revision: 2, sessionId: "session-2", title: "Second Page Updated", nextOffset: nil, totalCount: 2),
      ]
    )
    let harness = makeHarness(loader: fixture.loader)
    let service = LibraryDataService()
    defer { service.stopLiveUpdates() }

    await service.refreshNow(runtimeRegistry: harness.registry)
    await service.loadMore(runtimeRegistry: harness.registry)
    #expect(Set(service.sessions.map(\.displayTitle)) == ["First Page", "Second Page"])

    service.startLiveUpdates(runtimeRegistry: harness.registry)
    harness.connection.emitForTesting(.archivedSessionsInvalidated(revision: 2))
    await fixture.waitForRequestCount(4)
    await drainMainActorTasks()

    #expect(Set(service.sessions.map(\.displayTitle)) == ["First Page Updated", "Second Page Updated"])
    #expect(
      await fixture.requestPaths()
        == ["/api/sessions/archive", "/api/sessions/archive", "/api/sessions/archive", "/api/sessions/archive"]
    )
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

private actor LibraryLoaderFixture {
  enum Response {
    case snapshot(revision: UInt64, title: String)
    case page(revision: UInt64, sessionId: String, title: String, nextOffset: UInt64?, totalCount: UInt64)
  }

  private var queuedResponses: [Response]
  private var paths: [String] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var afterFirstResponse: (@MainActor @Sendable () -> Void)?
  private var hasTriggeredAfterFirstResponse = false

  init(
    responses: [Response],
    afterFirstResponse: (@MainActor @Sendable () -> Void)? = nil
  ) {
    queuedResponses = responses
    self.afterFirstResponse = afterFirstResponse
  }

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    paths.append(url.path)
    flushWaiters()
    guard url.path == "/api/sessions/archive" else {
      throw URLError(.badURL)
    }

    let response = queuedResponses.isEmpty ? .snapshot(revision: 1, title: "Fallback") : queuedResponses.removeFirst()
    let body: Data
    switch response {
      case let .snapshot(revision, title):
        body = responseBody(
          revision: revision,
          sessionId: "session-1",
          title: title,
          nextOffset: nil,
          totalCount: 1
        )

      case let .page(revision, sessionId, title, nextOffset, totalCount):
        body = responseBody(
          revision: revision,
          sessionId: sessionId,
          title: title,
          nextOffset: nextOffset,
          totalCount: totalCount
        )
    }

    if !hasTriggeredAfterFirstResponse {
      hasTriggeredAfterFirstResponse = true
      if let afterFirstResponse {
        await MainActor.run {
          afterFirstResponse()
        }
        await Task.yield()
      }
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

  private func responseBody(
    revision: UInt64,
    sessionId: String,
    title: String,
    nextOffset: UInt64?,
    totalCount: UInt64
  ) -> Data {
    let lastActivityAt = sessionId.hasSuffix("2")
      ? "2026-04-14T12:02:00Z"
      : "2026-04-14T12:01:00Z"
    return Data(
      """
      {
        "revision": \(revision),
        "sessions": [
          {
            "id": "\(sessionId)",
            "provider": "codex",
            "project_path": "/tmp/project",
            "project_name": "Project",
            "git_branch": "main",
            "model": "gpt-5",
            "status": "active",
            "work_status": "working",
            "control_mode": "direct",
            "lifecycle_state": "open",
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
            "list_status": "working",
            "summary_revision": 1,
            "effort": null,
            "active_worker_count": 0,
            "pending_tool_family": null,
            "forked_from_session_id": null,
            "mission_id": null,
            "issue_identifier": null
          }
        ],
        "next_offset": \(nextOffset.map(String.init) ?? "null"),
        "total_count": \(totalCount)
      }
      """.utf8
    )
  }

  func waitForRequestCount(_ expected: Int) async {
    if paths.count >= expected {
      return
    }
    await withCheckedContinuation { continuation in
      requestWaiters.append((expected, continuation))
    }
  }

  private func flushWaiters() {
    var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
    for (expected, continuation) in requestWaiters {
      if paths.count >= expected {
        continuation.resume()
      } else {
        remaining.append((expected, continuation))
      }
    }
    requestWaiters = remaining
  }
}
