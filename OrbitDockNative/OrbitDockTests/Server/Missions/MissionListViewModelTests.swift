import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct MissionListViewModelTests {
  @Test func activationLoadsMissionsAndDeactivationTurnsOffRealtime() async throws {
    let fixture = MissionListLoaderFixture(
      responses: [.snapshot(revision: 1, missionName: "Activated Mission")]
    )
    let harness = makeHarness(loader: fixture.loader)
    let viewModel = MissionListViewModel()

    await viewModel.activate(runtimeRegistry: harness.registry)

    #expect(viewModel.missions.map(\.mission.name) == ["Activated Mission"])
    #expect(viewModel.isLoading == false)

    harness.connection.emitForTesting(.connectionStatusChanged(.connected))
    await drainMainActorTasks()
    #expect(harness.connection.hasSubscribedMissionsStream)

    viewModel.deactivate()

    #expect(harness.connection.hasSubscribedMissionsStream == false)
  }

  @Test func missionListFetchesMissionsEndpointAndRefreshesOnListInvalidation() async throws {
    let fixture = MissionListLoaderFixture(
      responses: [
        .snapshot(revision: 1, missionName: "Initial Mission"),
        .snapshot(revision: 2, missionName: "Updated Mission"),
      ]
    )
    let harness = makeHarness(loader: fixture.loader)
    let viewModel = MissionListViewModel()

    viewModel.bind(runtimeRegistry: harness.registry)
    viewModel.setRealtimeUpdatesEnabled(true)
    await viewModel.fetchAllMissions()

    #expect(viewModel.missions.map(\.mission.name) == ["Initial Mission"])
    #expect(await fixture.requestPaths() == ["/api/missions"])

    harness.connection.emitForTesting(.missionsInvalidated(revision: 2))
    await fixture.waitForRequestCount(2)
    await drainMainActorTasks()

    #expect(viewModel.missions.map(\.mission.name) == ["Updated Mission"])
    #expect(await fixture.requestPaths() == ["/api/missions", "/api/missions"])
  }

  @Test func missionListIgnoresMissionScopedRealtimeEvents() async throws {
    let fixture = MissionListLoaderFixture(
      responses: [
        .snapshot(revision: 1, missionName: "Stable Mission"),
      ]
    )
    let harness = makeHarness(loader: fixture.loader)
    let viewModel = MissionListViewModel()

    viewModel.bind(runtimeRegistry: harness.registry)
    viewModel.setRealtimeUpdatesEnabled(true)
    await viewModel.fetchAllMissions()

    harness.connection.emitForTesting(.missionInvalidated(missionId: "mission-1", revision: 2))
    harness.connection.emitForTesting(
      .missionHeartbeat(
        missionId: "mission-1",
        tickStartedAt: "2026-04-14T15:00:00.000Z",
        nextTickAt: "2026-04-14T15:01:00.000Z"
      )
    )
    await drainMainActorTasks()

    #expect(viewModel.missions.map(\.mission.name) == ["Stable Mission"])
    #expect(await fixture.requestPaths() == ["/api/missions"])
  }

  @Test func disablingRealtimeUnsubscribesMissionsStream() async throws {
    let fixture = MissionListLoaderFixture(
      responses: [.snapshot(revision: 1, missionName: "Stable Mission")]
    )
    let harness = makeHarness(loader: fixture.loader)
    let viewModel = MissionListViewModel()

    viewModel.bind(runtimeRegistry: harness.registry)
    viewModel.setRealtimeUpdatesEnabled(true)
    harness.connection.emitForTesting(.connectionStatusChanged(.connected))
    await drainMainActorTasks()
    #expect(harness.connection.hasSubscribedMissionsStream)

    viewModel.setRealtimeUpdatesEnabled(false)

    #expect(harness.connection.hasSubscribedMissionsStream == false)
  }

  @Test func applyingMissionListReplacesOnlyThatEndpointSlice() async throws {
    let viewModel = MissionListViewModel()
    let primaryEndpoint = UUID()
    let secondaryEndpoint = UUID()

    viewModel.missions = [
      AggregatedMissionSummary(
        mission: MissionSummary.fixture(id: "mission-a", name: "Primary Old"),
        endpointId: primaryEndpoint,
        endpointName: "Primary"
      ),
      AggregatedMissionSummary(
        mission: MissionSummary.fixture(id: "mission-b", name: "Secondary Stable"),
        endpointId: secondaryEndpoint,
        endpointName: "Secondary"
      ),
    ]

    viewModel.applyMissionList(
      ServerMissionSnapshotPayload(
        revision: 9,
        missions: [MissionSummary.fixture(id: "mission-c", name: "Primary New")]
      ),
      endpointId: primaryEndpoint,
      endpointName: "Primary"
    )

    #expect(viewModel.missions.map(\.mission.name) == ["Primary New", "Secondary Stable"])
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

private extension MissionSummary {
  static func fixture(id: String, name: String) -> MissionSummary {
    MissionSummary(
      id: id,
      name: name,
      repoRoot: "/tmp/project",
      enabled: true,
      paused: false,
      trackerKind: "linear",
      provider: "claude",
      providerStrategy: "single",
      primaryProvider: "claude",
      secondaryProvider: nil,
      activeCount: 1,
      queuedCount: 0,
      completedCount: 0,
      failedCount: 0,
      parseError: nil,
      orchestratorStatus: "polling",
      lastPolledAt: nil,
      pollInterval: 60,
      missionFilePath: "MISSION.md",
      trackerKeySource: nil
    )
  }
}

private actor MissionListLoaderFixture {
  enum Response {
    case snapshot(revision: UInt64, missionName: String)
  }

  private var queuedResponses: [Response]
  private var paths: [String] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(responses: [Response]) {
    queuedResponses = responses
  }

  func loader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    paths.append(url.path)
    flushWaiters()
    guard url.path == "/api/missions" else {
      throw URLError(.badURL)
    }

    let response = queuedResponses.isEmpty ? .snapshot(revision: 1, missionName: "Fallback Mission") : queuedResponses.removeFirst()
    let body: Data
    switch response {
      case let .snapshot(revision, missionName):
        body = responseBody(revision: revision, missionName: missionName)
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

  private func responseBody(revision: UInt64, missionName: String) -> Data {
    Data(
      """
      {
        "revision": \(revision),
        "missions": [
          {
            "id": "mission-1",
            "name": "\(missionName)",
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
          }
        ]
      }
      """.utf8
    )
  }

  func waitForRequestCount(_ count: Int) async {
    if paths.count >= count { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append((count, continuation))
    }
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
