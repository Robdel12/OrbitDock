import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerRuntimeRegistryRealtimeSubscriptionTests {
  @Test func connectedEventResubscribesDashboardWhenBootstrapWasLoadedBeforeHandshake() throws {
    let endpoint = try makeEndpoint(
      id: "f0f35c93-9f9f-4d18-b2ca-3f1226e7d7a1",
      name: "Primary",
      isEnabled: true,
      isDefault: true,
      port: 4_040
    )
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)
    let runtime = try #require(registry.runtimesByEndpointId[endpoint.id])

    runtime.connection.seedDashboardSnapshotForTesting(
      ServerDashboardSnapshotPayload(
        revision: 12,
        sessions: [],
        conversations: [],
        counts: ServerDashboardCounts(attention: 0, running: 0, ready: 0, direct: 0)
      )
    )
    runtime.connection.applyMissionsSnapshot(
      ServerMissionSnapshotPayload(revision: 4, missions: [])
    )
    #expect(runtime.connection.hasSubscribedDashboardStream == false)

    runtime.connection.emitForTesting(.connectionStatusChanged(.connected))

    #expect(runtime.connection.hasSubscribedDashboardStream)
  }

  @Test func sessionDeltaDoesNotMutateDashboardConversationProjection() async throws {
    let endpoint = try makeEndpoint(
      id: "88a6b9fb-90e4-4cb3-a95f-0f0b65819318",
      name: "Primary",
      isEnabled: true,
      isDefault: true,
      port: 4_041
    )
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)
    let runtime = try #require(registry.runtimesByEndpointId[endpoint.id])

    runtime.connection.seedDashboardSnapshotForTesting(
      ServerDashboardSnapshotPayload(
        revision: 30,
        sessions: [],
        conversations: [try makeDashboardConversationItem(workStatus: "reply", listStatus: "reply")],
        counts: ServerDashboardCounts(attention: 0, running: 0, ready: 1, direct: 1)
      )
    )
    await drainMainActorTasks()

    let initial = try #require(registry.aggregatedDashboardConversations.first)
    #expect(initial.displayStatus == .reply)

    runtime.connection.emitForTesting(
      .sessionDelta(
        sessionId: "session-1",
        changes: ServerStateChanges(
          status: .active,
          workStatus: .permission,
          lastActivityAt: "2026-03-30T15:30:00Z"
        )
      )
    )
    await drainMainActorTasks()

    let updated = try #require(registry.aggregatedDashboardConversations.first)
    #expect(updated.displayStatus == .reply)
    #expect(updated.canEnd == true)
  }

  private func makeEndpoint(
    id: String,
    name: String,
    isEnabled: Bool,
    isDefault: Bool,
    port: Int
  ) throws -> ServerEndpoint {
    try ServerEndpoint(
      id: #require(UUID(uuidString: id)),
      name: name,
      wsURL: #require(URL(string: "ws://127.0.0.1:\(port)/ws")),
      isEnabled: isEnabled,
      isDefault: isDefault
    )
  }

  private func makeDashboardConversationItem(
    workStatus: String,
    listStatus: String
  ) throws -> ServerDashboardConversationItem {
    let json = """
    {
      "session_id": "session-1",
      "provider": "codex",
      "project_path": "/tmp/orbitdock",
      "project_name": "OrbitDock",
      "repository_root": "/tmp/orbitdock",
      "git_branch": "main",
      "is_worktree": false,
      "worktree_id": null,
      "model": "gpt-5",
      "codex_integration_mode": "direct",
      "status": "active",
      "work_status": "\(workStatus)",
      "control_mode": "direct",
      "lifecycle_state": "open",
      "list_status": "\(listStatus)",
      "display_title": "Dashboard Session",
      "context_line": "Investigate dashboard controls",
      "last_message": "Working through the UI",
      "preview_text": "Working through the UI",
      "activity_summary": "Working through the UI",
      "alert_context": "Working through the UI",
      "started_at": "2026-03-20T10:00:00Z",
      "last_activity_at": "2026-03-20T11:00:00Z",
      "unread_count": 0,
      "has_turn_diff": false,
      "diff_preview": null,
      "pending_tool_name": null,
      "pending_tool_input": null,
      "pending_question": null,
      "tool_count": 0,
      "active_worker_count": 0,
      "issue_identifier": null,
      "effort": "high"
    }
    """

    let data = try #require(json.data(using: .utf8))
    return try JSONDecoder().decode(ServerDashboardConversationItem.self, from: data)
  }

  private func drainMainActorTasks(iterations: Int = 10) async {
    for _ in 0..<iterations {
      await Task.yield()
    }
  }
}
