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

  @Test func conversationBootstrapDecodesWorkerRowsFromSessionPayload() throws {
    let data = Data(
      """
      {
        "session": {
          "id": "session-worker",
          "provider": "codex",
          "project_path": "/tmp/orbitdock",
          "project_name": "OrbitDock",
          "status": "active",
          "work_status": "working",
          "token_usage": {
            "input_tokens": 12,
            "output_tokens": 34,
            "cached_tokens": 0,
            "context_window": 200000
          },
          "rows": [
            {
              "session_id": "session-worker",
              "sequence": 7,
              "turn_id": "turn-1",
              "row": {
                "row_type": "worker",
                "id": "worker-row-1",
                "title": "Repo Scout",
                "subtitle": "Mapping the repository",
                "summary": "Scanning files",
                "worker": {
                  "subagent_id": "worker-1",
                  "label": "Scout",
                  "status": "running"
                },
                "operation": "spawned",
                "render_hints": {
                  "can_expand": true,
                  "default_expanded": false,
                  "emphasized": true,
                  "monospace_summary": false,
                  "accent_tone": "cyan"
                }
              }
            }
          ],
          "total_row_count": 1,
          "has_more_before": false,
          "oldest_sequence": 7,
          "newest_sequence": 7
        },
        "total_row_count": 1,
        "has_more_before": false,
        "oldest_sequence": 7,
        "newest_sequence": 7
      }
      """.utf8
    )

    let bootstrap = try JSONDecoder().decode(ServerConversationBootstrap.self, from: data)

    #expect(bootstrap.session.projectName == "OrbitDock")
    #expect(bootstrap.rows.count == 1)
    #expect(bootstrap.rows.first?.id == "worker-row-1")

    guard case let .worker(row)? = bootstrap.rows.first?.row else {
      Issue.record("Expected worker row in bootstrap payload")
      return
    }

    #expect(row.renderHints.canExpand == true)
    #expect(row.operation == "spawned")
  }
}
