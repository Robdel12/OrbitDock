import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct DashboardSnapshotTests {
  @Test func snapshotCachesVisibleProjectGroupsAndDeduplicatedSessionRefs() throws {
    let endpointId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let activeRecord = try makeRecord(
      sessionId: "session-active",
      endpointId: endpointId,
      projectPath: "/tmp/orbitdock",
      projectName: "OrbitDock",
      repositoryRoot: "/tmp/orbitdock",
      listStatus: "working"
    )
    let endedRecord = try makeRecord(
      sessionId: "session-ended",
      endpointId: endpointId,
      projectPath: "/tmp/archive",
      projectName: "Archive",
      repositoryRoot: "/tmp/archive",
      listStatus: "ended",
      status: "ended",
      workStatus: "ended"
    )

    let activeGroup = DashboardProjectGroup(
      path: "/tmp/orbitdock",
      name: "OrbitDock",
      endpointId: endpointId,
      endpointName: "Preview Server",
      attentionCount: 0,
      workingCount: 2,
      readyCount: 0,
      sessionIds: ["session-active", "session-active", "session-shadow"],
      lastActivityAt: Date()
    )
    let endedGroup = DashboardProjectGroup(
      path: "/tmp/archive",
      name: "Archive",
      endpointId: endpointId,
      endpointName: "Preview Server",
      attentionCount: 0,
      workingCount: 0,
      readyCount: 0,
      sessionIds: ["session-ended"],
      lastActivityAt: Date()
    )

    let snapshot = DashboardSnapshot(
      revision: 7,
      conversations: [activeRecord, endedRecord],
      counts: DashboardTriageCounts(conversations: [activeRecord, endedRecord]),
      directCount: 1,
      hasMultipleEndpoints: false,
      projectGroups: [activeGroup, endedGroup]
    )

    #expect(snapshot.visibleProjectGroups.map(\.id) == [activeGroup.id])
    #expect(snapshot.sessionRefs(for: activeGroup) == [
      SessionRef(endpointId: endpointId, sessionId: "session-active"),
      SessionRef(endpointId: endpointId, sessionId: "session-shadow"),
    ])
    #expect(snapshot.conversationsBySessionRef[activeRecord.sessionRef] == activeRecord)
    #expect(snapshot.conversationsBySessionRef[endedRecord.sessionRef] == endedRecord)
  }

  @Test func replacingRebuildsSnapshotCachesForUpdatedConversations() throws {
    let endpointId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let first = try makeRecord(
      sessionId: "session-1",
      endpointId: endpointId,
      projectPath: "/tmp/orbitdock",
      projectName: "OrbitDock",
      repositoryRoot: "/tmp/orbitdock",
      listStatus: "working"
    )
    let second = try makeRecord(
      sessionId: "session-2",
      endpointId: endpointId,
      projectPath: "/tmp/orbitdock",
      projectName: "OrbitDock",
      repositoryRoot: "/tmp/orbitdock",
      listStatus: "reply"
    )

    let original = DashboardSnapshot(
      revision: 1,
      conversations: [first],
      counts: DashboardTriageCounts(conversations: [first]),
      directCount: 1,
      hasMultipleEndpoints: false,
      projectGroups: DashboardSnapshot.buildProjectGroups(from: [first])
    )
    let updated = original.replacing(conversations: [first, second], revision: 2)
    let group = try #require(updated.visibleProjectGroups.first)

    #expect(updated.revision == 2)
    #expect(updated.conversationsBySessionRef[second.sessionRef] == second)
    #expect(updated.sessionRefs(for: group) == [first.sessionRef, second.sessionRef])
  }

  private func makeRecord(
    sessionId: String,
    endpointId: UUID,
    projectPath: String,
    projectName: String,
    repositoryRoot: String,
    listStatus: String,
    status: String = "active",
    workStatus: String = "working"
  ) throws -> DashboardConversationRecord {
    let json = """
    {
      "session_id": "\(sessionId)",
      "provider": "codex",
      "project_path": "\(projectPath)",
      "project_name": "\(projectName)",
      "repository_root": "\(repositoryRoot)",
      "git_branch": "main",
      "is_worktree": false,
      "worktree_id": null,
      "model": "gpt-5",
      "codex_integration_mode": "direct",
      "status": "\(status)",
      "work_status": "\(workStatus)",
      "control_mode": "direct",
      "lifecycle_state": "open",
      "list_status": "\(listStatus)",
      "display_title": "Dashboard Session",
      "context_line": "Investigate dashboard performance",
      "last_message": "Working through the backlog",
      "started_at": "2026-03-20T10:00:00Z",
      "last_activity_at": "2026-03-20T11:00:00Z",
      "unread_count": 0,
      "has_turn_diff": false,
      "diff_preview": null,
      "pending_tool_name": null,
      "pending_tool_input": null,
      "pending_question": null,
      "tool_count": 0,
      "active_worker_count": 1,
      "issue_identifier": null,
      "effort": null
    }
    """

    let data = try #require(json.data(using: .utf8))
    let item = try JSONDecoder().decode(ServerDashboardConversationItem.self, from: data)
    return DashboardConversationRecord(
      item: item,
      endpointId: endpointId,
      endpointName: "Preview Server"
    )
  }
}
