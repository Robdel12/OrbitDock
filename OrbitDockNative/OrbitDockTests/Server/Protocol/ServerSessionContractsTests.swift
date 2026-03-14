import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerSessionContractsTests {
  @Test func sessionListItemDecodesSummaryRevision() throws {
    let data = Data(
      """
      {
        "id": "session-1",
        "provider": "codex",
        "project_path": "/tmp/orbitdock",
        "project_name": "OrbitDock",
        "git_branch": "main",
        "model": "gpt-5.4",
        "status": "active",
        "work_status": "working",
        "codex_integration_mode": "passive",
        "started_at": "2026-03-11T01:00:00Z",
        "last_activity_at": "2026-03-11T02:00:00Z",
        "unread_count": 2,
        "has_turn_diff": false,
        "repository_root": "/tmp/orbitdock",
        "is_worktree": false,
        "total_tokens": 42,
        "total_cost_usd": 0,
        "display_title": "OrbitDock",
        "display_title_sort_key": "orbitdock",
        "display_search_text": "orbitdock main",
        "context_line": "Context",
        "list_status": "working",
        "summary_revision": 17
      }
      """.utf8
    )

    let item = try JSONDecoder().decode(ServerSessionListItem.self, from: data)

    #expect(item.id == "session-1")
    #expect(item.summaryRevision == 17)
  }

  @Test func sessionSummaryDecodesSummaryRevision() throws {
    let data = Data(
      """
      {
        "id": "session-2",
        "provider": "codex",
        "project_path": "/tmp/orbitdock",
        "project_name": "OrbitDock",
        "status": "active",
        "work_status": "reply",
        "has_pending_approval": false,
        "is_worktree": false,
        "unread_count": 0,
        "display_title": "OrbitDock",
        "display_title_sort_key": "orbitdock",
        "display_search_text": "orbitdock",
        "list_status": "reply",
        "summary_revision": 29
      }
      """.utf8
    )

    let summary = try JSONDecoder().decode(ServerSessionSummary.self, from: data)

    #expect(summary.id == "session-2")
    #expect(summary.summaryRevision == 29)
  }
}
