import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct DashboardPresentationBuilderTests {
  @Test func recentSortPreservesServerConversationOrder() throws {
    let first = try makeRecord(sessionId: "session-b", title: "Zulu", listStatus: "working")
    let second = try makeRecord(sessionId: "session-a", title: "Alpha", listStatus: "reply")
    let snapshot = makeSnapshot(conversations: [first, second])

    let presentation = DashboardPresentationBuilder.build(
      snapshot: snapshot,
      filter: .all,
      sort: .recent,
      providerFilter: .all,
      projectFilter: nil,
      projectOrder: []
    )

    #expect(presentation.filteredConversations.map(\.id) == [first.id, second.id])
  }

  @Test func statusSortPreservesServerConversationOrder() throws {
    let first = try makeRecord(sessionId: "session-attention", title: "Needs Input", listStatus: "permission")
    let second = try makeRecord(sessionId: "session-working", title: "Working", listStatus: "working")
    let snapshot = makeSnapshot(conversations: [first, second])

    let presentation = DashboardPresentationBuilder.build(
      snapshot: snapshot,
      filter: .all,
      sort: .status,
      providerFilter: .all,
      projectFilter: nil,
      projectOrder: []
    )

    #expect(presentation.filteredConversations.map(\.id) == [first.id, second.id])
  }

  @Test func nameSortStillAppliesClientSideOrdering() throws {
    let first = try makeRecord(sessionId: "session-b", title: "Zulu", listStatus: "working")
    let second = try makeRecord(sessionId: "session-a", title: "Alpha", listStatus: "reply")
    let snapshot = makeSnapshot(conversations: [first, second])

    let presentation = DashboardPresentationBuilder.build(
      snapshot: snapshot,
      filter: .all,
      sort: .name,
      providerFilter: .all,
      projectFilter: nil,
      projectOrder: []
    )

    #expect(presentation.filteredConversations.map(\.id) == [second.id, first.id])
  }

  private func makeSnapshot(conversations: [DashboardConversationRecord]) -> DashboardSnapshot {
    DashboardSnapshot(
      revision: 1,
      conversations: conversations,
      counts: DashboardTriageCounts(conversations: conversations),
      directCount: conversations.filter(\.isDirect).count,
      hasMultipleEndpoints: false,
      projectGroups: DashboardSnapshot.buildProjectGroups(from: conversations)
    )
  }

  private func makeRecord(
    sessionId: String,
    title: String,
    listStatus: String
  ) throws -> DashboardConversationRecord {
    let json = """
    {
      "session_id": "\(sessionId)",
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
      "work_status": "working",
      "control_mode": "direct",
      "lifecycle_state": "open",
      "list_status": "\(listStatus)",
      "display_title": "\(title)",
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
      endpointId: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
      endpointName: "Preview Server"
    )
  }
}
