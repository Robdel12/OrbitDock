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
        "control_mode": "passive",
        "lifecycle_state": "open",
        "steerable": false,
        "codex_integration_mode": "passive",
        "started_at": "2026-03-11T01:00:00Z",
        "last_activity_at": "2026-03-11T02:00:00Z",
        "unread_count": 2,
        "has_turn_diff": false,
        "repository_root": "/tmp/orbitdock",
        "is_worktree": false,
        "total_tokens": 42,
        "total_cost_usd": 0,
        "input_tokens": 20,
        "output_tokens": 22,
        "cached_tokens": 0,
        "display_title": "OrbitDock",
        "display_title_sort_key": "orbitdock",
        "display_search_text": "orbitdock main",
        "context_line": "Context",
        "list_status": "working",
        "summary_revision": 17,
        "active_worker_count": 0
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
        "control_mode": "passive",
        "lifecycle_state": "open",
        "accepts_user_input": true,
        "steerable": false,
        "token_usage": {
          "input_tokens": 10,
          "output_tokens": 20,
          "cached_tokens": 0,
          "context_window": 200000
        },
        "token_usage_snapshot_kind": "lifetime_totals",
        "has_pending_approval": false,
        "allow_bypass_permissions": false,
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
          "control_mode": "direct",
          "lifecycle_state": "open",
          "accepts_user_input": true,
          "steerable": false,
          "token_usage": {
            "input_tokens": 12,
            "output_tokens": 34,
            "cached_tokens": 0,
            "context_window": 200000
          },
          "token_usage_snapshot_kind": "lifetime_totals",
          "allow_bypass_permissions": false,
          "is_worktree": false,
          "unread_count": 0,
          "turn_count": 1,
          "turn_diffs": [],
          "subagents": [],
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
                  "id": "worker-1",
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

  @Test func conversationBootstrapDefaultsMissingQuestionPromptsAndActivityChildren() throws {
    let data = Data(
      """
      {
        "session": {
          "id": "session-compat",
          "provider": "claude",
          "project_path": "/tmp/orbitdock",
          "project_name": "OrbitDock",
          "status": "active",
          "work_status": "permission",
          "control_mode": "direct",
          "lifecycle_state": "open",
          "accepts_user_input": true,
          "steerable": false,
          "token_usage": {
            "input_tokens": 1,
            "output_tokens": 2,
            "cached_tokens": 0,
            "context_window": 200000
          },
          "token_usage_snapshot_kind": "lifetime_totals",
          "allow_bypass_permissions": false,
          "is_worktree": false,
          "unread_count": 0,
          "turn_count": 2,
          "turn_diffs": [],
          "subagents": [],
          "rows": [
            {
              "session_id": "session-compat",
              "sequence": 1,
              "row": {
                "row_type": "question",
                "id": "question-row-1",
                "title": "Need guidance",
                "render_hints": {
                  "can_expand": false,
                  "default_expanded": false,
                  "emphasized": false,
                  "monospace_summary": false
                }
              }
            },
            {
              "session_id": "session-compat",
              "sequence": 2,
              "row": {
                "row_type": "activity_group",
                "id": "group-row-1",
                "group_kind": "tool_block",
                "title": "Grouped tools",
                "child_count": 0,
                "status": "completed",
                "render_hints": {
                  "can_expand": true,
                  "default_expanded": false,
                  "emphasized": false,
                  "monospace_summary": false
                }
              }
            }
          ],
          "total_row_count": 2,
          "has_more_before": false,
          "oldest_sequence": 1,
          "newest_sequence": 2
        },
        "total_row_count": 2,
        "has_more_before": false,
        "oldest_sequence": 1,
        "newest_sequence": 2
      }
      """.utf8
    )

    let bootstrap = try JSONDecoder().decode(ServerConversationBootstrap.self, from: data)

    guard case let .question(questionRow) = bootstrap.rows.first?.row else {
      Issue.record("Expected question row in bootstrap payload")
      return
    }
    #expect(questionRow.prompts.isEmpty)

    guard case let .activityGroup(groupRow) = bootstrap.rows.last?.row else {
      Issue.record("Expected activity group row in bootstrap payload")
      return
    }
    #expect(groupRow.children.isEmpty)
    #expect(groupRow.childCount == 0)
  }

  @Test func conversationBootstrapDefaultsMissingShellCommandArgs() throws {
    let data = Data(
      """
      {
        "session": {
          "id": "session-shell-compat",
          "provider": "claude",
          "project_path": "/tmp/orbitdock",
          "project_name": "OrbitDock",
          "status": "active",
          "work_status": "working",
          "control_mode": "direct",
          "lifecycle_state": "open",
          "accepts_user_input": true,
          "steerable": false,
          "token_usage": {
            "input_tokens": 3,
            "output_tokens": 5,
            "cached_tokens": 0,
            "context_window": 200000
          },
          "token_usage_snapshot_kind": "lifetime_totals",
          "allow_bypass_permissions": false,
          "is_worktree": false,
          "unread_count": 0,
          "turn_count": 1,
          "turn_diffs": [],
          "subagents": [],
          "rows": [
            {
              "session_id": "session-shell-compat",
              "sequence": 4,
              "row": {
                "row_type": "shell_command",
                "id": "shell-row-1",
                "kind": "bash",
                "title": "git status",
                "command": "git status"
              }
            }
          ],
          "total_row_count": 1,
          "has_more_before": false,
          "oldest_sequence": 4,
          "newest_sequence": 4
        },
        "total_row_count": 1,
        "has_more_before": false,
        "oldest_sequence": 4,
        "newest_sequence": 4
      }
      """.utf8
    )

    let bootstrap = try JSONDecoder().decode(ServerConversationBootstrap.self, from: data)

    guard case let .shellCommand(shellRow) = bootstrap.rows.first?.row else {
      Issue.record("Expected shell command row in bootstrap payload")
      return
    }

    #expect(shellRow.args.isEmpty)
    #expect(shellRow.command == "git status")
  }

  @Test func conversationBootstrapDecodesStringApprovalPolicyDetails() throws {
    let data = Data(
      """
      {
        "session": {
          "id": "session-approval-policy",
          "provider": "codex",
          "project_path": "/tmp/orbitdock",
          "project_name": "OrbitDock",
          "status": "active",
          "work_status": "waiting",
          "control_mode": "direct",
          "lifecycle_state": "open",
          "accepts_user_input": true,
          "steerable": false,
          "codex_config_mode": "custom",
          "approval_policy": "on-request",
          "approval_policy_details": "on-request",
          "token_usage": {
            "input_tokens": 8,
            "output_tokens": 13,
            "cached_tokens": 0,
            "context_window": 200000
          },
          "token_usage_snapshot_kind": "lifetime_totals",
          "allow_bypass_permissions": false,
          "is_worktree": false,
          "unread_count": 0,
          "turn_count": 0,
          "turn_diffs": [],
          "subagents": [],
          "rows": [],
          "total_row_count": 0,
          "has_more_before": false
        },
        "total_row_count": 0,
        "has_more_before": false
      }
      """.utf8
    )

    let bootstrap = try JSONDecoder().decode(ServerConversationBootstrap.self, from: data)

    #expect(bootstrap.session.approvalPolicyDetails == .mode(.onRequest))
    #expect(bootstrap.session.codexConfigMode == .custom)
  }
}
