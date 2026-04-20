import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct MissionControlViewModelTests {
  @Test func activationLoadsMissionDetail() async {
    let fixture = MissionDetailLoaderFixture(
      responses: [.detail(name: "Loaded Mission")]
    )
    let harness = await makeHarness(loader: fixture.loader)
    let viewModel = MissionControlViewModel()

    await viewModel.activate(
      missionId: "mission-1",
      endpointId: harness.runtime.endpoint.id,
      runtimeRegistry: harness.registry
    )

    #expect(await fixture.requestPaths() == ["/api/missions/mission-1"])
    #expect(viewModel.summary?.name == "Loaded Mission")
    #expect(viewModel.isLoading == false)
  }

  @Test func missionHeartbeatUpdatesTimingWithoutReplacingDetailState() throws {
    let endpoint = try ServerEndpoint(
      id: UUID(),
      name: "Primary",
      wsURL: #require(URL(string: "ws://127.0.0.1:3000/ws"))
    )
    let connection = ServerConnection(authToken: nil)
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://127.0.0.1:3000")),
      authToken: nil,
      dataLoader: { _ in
        throw URLError(.badServerResponse)
      }
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

    let viewModel = MissionControlViewModel()
    viewModel.bind(missionId: "mission-1", endpointId: endpoint.id, runtimeRegistry: registry)

    let initialSummary = MissionSummary(
      id: "mission-1",
      name: "Initial",
      repoRoot: "/repo",
      enabled: true,
      paused: false,
      trackerKind: "linear",
      providerStrategy: "single",
      primaryProvider: "claude",
      secondaryProvider: nil,
      activeCount: 0,
      queuedCount: 0,
      completedCount: 0,
      failedCount: 0,
      parseError: nil,
      orchestratorStatus: nil,
      lastPolledAt: nil,
      pollInterval: nil,
      missionFilePath: nil,
      trackerKeySource: nil
    )
    let initialDetail = MissionDetailResponse(
      summary: initialSummary,
      issues: [],
      cleanupPrompt: nil,
      settings: nil,
      missionFileExists: true,
      missionFilePath: nil
    )
    viewModel.applyDetail(initialDetail)
    viewModel.isLoading = false

    connection.emitForTesting(
      .missionHeartbeat(
        missionId: "mission-1",
        tickStartedAt: "2026-04-14T15:00:00.000Z",
        nextTickAt: "2026-04-14T15:01:00.000Z"
      )
    )

    #expect(viewModel.summary?.name == "Initial")
    #expect(viewModel.issues.isEmpty)
    #expect(viewModel.isLoading == false)
    #expect(viewModel.nextTickAt != nil)
    #expect(viewModel.lastTickAt != nil)
  }

  @Test func missionDetailRefreshesOnlyOnMissionScopedInvalidation() async throws {
    let endpoint = try ServerEndpoint(
      id: UUID(),
      name: "Primary",
      wsURL: #require(URL(string: "ws://127.0.0.1:3000/ws"))
    )
    let connection = ServerConnection(authToken: nil)
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://127.0.0.1:3000")),
      authToken: nil,
      dataLoader: { _ in
        throw URLError(.badServerResponse)
      }
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

    let viewModel = MissionControlViewModel()
    viewModel.bind(missionId: "mission-1", endpointId: endpoint.id, runtimeRegistry: registry)
    viewModel.error = nil

    connection.emitForTesting(.missionsInvalidated(revision: 1))
    await Task.yield()
    #expect(viewModel.error == nil)

    connection.emitForTesting(.missionInvalidated(missionId: "mission-2", revision: 2))
    await Task.yield()
    #expect(viewModel.error == nil)

    connection.emitForTesting(.missionInvalidated(missionId: "mission-1", revision: 3))
    await Task.yield()
    await Task.yield()
    #expect(viewModel.error != nil)
  }

  @Test func repeatedMissionInvalidationsCoalesceIntoOneFollowupRefresh() async {
    let fixture = MissionDetailLoaderFixture(
      pauseFirstRequest: true,
      responses: [
        .detail(name: "Initial Mission"),
        .detail(name: "Updated Mission"),
      ]
    )
    let harness = await makeHarness(loader: fixture.loader)
    let viewModel = MissionControlViewModel()

    viewModel.bind(
      missionId: "mission-1",
      endpointId: harness.runtime.endpoint.id,
      runtimeRegistry: harness.registry
    )

    let firstRefresh = Task { await viewModel.refreshDetail() }
    await fixture.waitForRequestCount(1)

    harness.connection.emitForTesting(.missionInvalidated(missionId: "mission-1", revision: 2))
    harness.connection.emitForTesting(.missionInvalidated(missionId: "mission-1", revision: 3))

    await fixture.releaseFirstRequest()
    await firstRefresh.value
    await fixture.waitForRequestCount(2)
    await Task.yield()

    #expect(await fixture.requestPaths() == ["/api/missions/mission-1", "/api/missions/mission-1"])
    #expect(viewModel.summary?.name == "Updated Mission")
  }

  @Test func transitionIssueUsesMissionClientAndAppliesReturnedDetail() async {
    let fixture = MissionDetailLoaderFixture(
      responses: [
        .transition(name: "Transitioned Mission"),
      ]
    )
    let harness = await makeHarness(loader: fixture.loader)
    let viewModel = MissionControlViewModel()

    viewModel.bind(
      missionId: "mission-1",
      endpointId: harness.runtime.endpoint.id,
      runtimeRegistry: harness.registry
    )

    await viewModel.transitionIssue(
      issueId: "issue-1",
      targetState: .blocked,
      reason: "Waiting on API cleanup"
    )

    #expect(
      await fixture.requestPaths()
        == ["/api/missions/mission-1/issues/issue-1/transition"]
    )
    #expect(viewModel.summary?.name == "Transitioned Mission")
    #expect(viewModel.error == nil)
  }

  @Test func presentingWorktreeCleanupLoadsSheetState() async {
    let fixture = MissionDetailLoaderFixture(
      responses: [.worktrees]
    )
    let harness = await makeHarness(loader: fixture.loader)
    let viewModel = MissionControlViewModel()
    viewModel.bind(
      missionId: "mission-1",
      endpointId: harness.runtime.endpoint.id,
      runtimeRegistry: harness.registry
    )

    await viewModel.presentWorktreeCleanup()

    #expect(viewModel.showWorktreeCleanup)
    #expect(viewModel.missionWorktrees.map(\.id) == ["worktree-1"])
    #expect(await fixture.requestPaths() == ["/api/missions/mission-1/worktrees"])
  }
}

private func makeHarness(
  loader: @escaping ServerClients.DataLoader
) async -> (registry: ServerRuntimeRegistry, runtime: ServerRuntime, connection: ServerConnection) {
  await MainActor.run {
    let endpoint = ServerEndpoint(
      id: UUID(),
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
    return (registry: registry, runtime: runtime, connection: connection)
  }
}

private actor MissionDetailLoaderFixture {
  enum Response {
    case detail(name: String)
    case transition(name: String)
    case worktrees
  }

  private var queuedResponses: [Response]
  private let pauseFirstRequest: Bool
  private var paths: [String] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var firstRequestContinuation: CheckedContinuation<Void, Never>?

  init(pauseFirstRequest: Bool = false, responses: [Response]) {
    self.pauseFirstRequest = pauseFirstRequest
    queuedResponses = responses
  }

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    paths.append(url.path)
    flushWaiters()

    if pauseFirstRequest, paths.count == 1 {
      await withCheckedContinuation { continuation in
        firstRequestContinuation = continuation
      }
    }

    let response = queuedResponses.isEmpty ? .detail(name: "Fallback Mission") : queuedResponses.removeFirst()
    let body: Data
    switch response {
      case let .detail(name):
        guard url.path == "/api/missions/mission-1" else {
          throw URLError(.badURL)
        }
        body = responseBody(name: name)
      case let .transition(name):
        guard url.path == "/api/missions/mission-1/issues/issue-1/transition" else {
          throw URLError(.badURL)
        }
        body = responseBody(name: name)
      case .worktrees:
        guard url.path == "/api/missions/mission-1/worktrees" else {
          throw URLError(.badURL)
        }
        body = worktreesResponseBody()
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

  func releaseFirstRequest() {
    firstRequestContinuation?.resume()
    firstRequestContinuation = nil
  }

  private func responseBody(name: String) -> Data {
    Data(
      """
      {
        "summary": {
          "id": "mission-1",
          "name": "\(name)",
          "repo_root": "/tmp/project",
          "enabled": true,
          "paused": false,
          "tracker_kind": "linear",
          "provider": "claude",
          "provider_strategy": "single",
          "primary_provider": "claude",
          "secondary_provider": null,
          "active_count": 1,
          "queued_count": 0,
          "completed_count": 0,
          "failed_count": 0,
          "parse_error": null,
          "orchestrator_status": "polling",
          "last_polled_at": null,
          "poll_interval": 60,
          "mission_file_path": "MISSION.md",
          "tracker_key_source": null
        },
        "issues": [],
        "cleanup_prompt": null,
        "settings": null,
        "mission_file_exists": true,
        "mission_file_path": "MISSION.md"
      }
      """.utf8
    )
  }

  private func worktreesResponseBody() -> Data {
    Data(
      """
      {
        "worktrees": [
          {
            "id": "worktree-1",
            "branch": "mission/worktree-1",
            "worktree_path": "/tmp/worktree-1",
            "disk_present": true,
            "orchestration_state": "completed",
            "issue_identifier": "OD-101",
            "issue_title": "Clean up lingering worktree"
          }
        ]
      }
      """.utf8
    )
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
}
