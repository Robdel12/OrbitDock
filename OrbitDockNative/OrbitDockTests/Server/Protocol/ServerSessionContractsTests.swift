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

  @Test func sessionDetailSnapshotDecodesRevision() throws {
    let data = Data(
      """
      {
        "revision": 29,
        "session": {
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
          "rows": [],
          "total_row_count": 0,
          "has_more_before": false,
          "token_usage": {
            "input_tokens": 10,
            "output_tokens": 20,
            "cached_tokens": 0,
            "context_window": 200000
          },
          "token_usage_snapshot_kind": "lifetime_totals",
          "allow_bypass_permissions": false,
          "turn_count": 0,
          "turn_diffs": [],
          "subagents": [],
          "is_worktree": false,
          "unread_count": 0,
          "revision": 29
        }
      }
      """.utf8
    )

    let payload = try JSONDecoder().decode(ServerSessionDetailSnapshotPayload.self, from: data)

    #expect(payload.revision == 29)
    #expect(payload.session.id == "session-2")
    #expect(payload.session.acceptsUserInput == true)
  }

  @Test func conversationBootstrapDecodesWorkerRowsFromSessionPayload() throws {
    let data = Data(
      """
      {
        "replay_cursor": 42,
        "forked_from_session_id": "session-root",
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
      }
      """.utf8
    )

    let bootstrap = try JSONDecoder().decode(ServerConversationBootstrap.self, from: data)

    #expect(bootstrap.forkedFromSessionId == "session-root")
    #expect(bootstrap.replayCursor == 42)
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

  @Test func toolRowDecodesShellExecutionSnakeCasePayload() throws {
    let data = Data(
      """
      {
        "session_id": "session-shell",
        "sequence": 12,
        "row": {
          "row_type": "tool",
          "id": "tool-shell-1",
          "provider": "codex",
          "family": "shell",
          "kind": "bash",
          "status": "completed",
          "title": "npm test",
          "subtitle": "/tmp/project",
          "summary": "done",
          "duration_ms": 42,
          "render_hints": {
            "can_expand": true,
            "default_expanded": false,
            "emphasized": false,
            "monospace_summary": true
          },
          "tool_display": {
            "summary": "npm test",
            "subtitle": "/tmp/project",
            "glyph_symbol": "terminal",
            "glyph_color": "green",
            "tool_type": "bash"
          },
          "shell_execution": {
            "command": "npm test",
            "cwd": "/tmp/project",
            "process_id": "pty-1",
            "actions": [
              { "type": "unknown", "command": "npm test" }
            ],
            "live_output_preview": "running",
            "aggregated_output": "done",
            "preview": {
              "kind": "status",
              "lines": ["done"],
              "overflow_count": 1
            },
            "exit_code": 0
          }
        }
      }
      """.utf8
    )

    let entry = try JSONDecoder().decode(ServerConversationRowEntry.self, from: data)

    guard case let .tool(tool) = entry.row else {
      Issue.record("Expected tool row")
      return
    }

    let shell = try #require(tool.shellExecution)
    #expect(shell.command == "npm test")
    #expect(shell.cwd == "/tmp/project")
    #expect(shell.processId == "pty-1")
    #expect(shell.liveOutputPreview == "running")
    #expect(shell.aggregatedOutput == nil)
    #expect(shell.preview?.overflowCount == 1)
    #expect(shell.exitCode == 0)
  }

  @Test func conversationBootstrapDecodesStringApprovalPolicyDetails() throws {
    let data = Data(
      """
      {
        "rows": [],
        "total_row_count": 0,
        "total_message_count": 9,
        "has_more_before": false,
        "forked_from_session_id": "root-session"
      }
      """.utf8
    )

    let bootstrap = try JSONDecoder().decode(ServerConversationBootstrap.self, from: data)

    #expect(bootstrap.totalRowCount == 0)
    #expect(bootstrap.forkedFromSessionId == "root-session")
  }
}
