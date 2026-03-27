import Foundation
@testable import OrbitDock
import Testing

struct DashboardConversationRecordTests {
  @Test func codexDirectConversationReportsDirectIntegration() throws {
    let record = try makeRecord(provider: "codex", codexIntegrationMode: "direct")

    #expect(record.integrationMode == .direct)
    #expect(record.isDirect == true)
    #expect(record.isPassive == false)
    #expect(record.canEnd == true)
  }

  @Test func codexPassiveConversationReportsPassiveIntegration() throws {
    let record = try makeRecord(provider: "codex", codexIntegrationMode: "passive")

    #expect(record.integrationMode == .passive)
    #expect(record.isDirect == false)
    #expect(record.isPassive == true)
  }

  @Test func claudeWithoutExplicitModeDefaultsToPassiveBadge() throws {
    let record = try makeRecord(provider: "claude")

    #expect(record.integrationMode == .passive)
    #expect(record.isDirect == false)
    #expect(record.isPassive == true)
  }

  @Test func endedConversationCannotBeEndedAgain() throws {
    let record = try makeRecord(
      provider: "claude",
      claudeIntegrationMode: "direct",
      listStatus: "ended",
      status: "ended",
      workStatus: "ended"
    )

    #expect(record.canEnd == false)
  }

  private func makeRecord(
    provider: String,
    codexIntegrationMode: String? = nil,
    claudeIntegrationMode: String? = nil,
    listStatus: String = "working",
    status: String = "active",
    workStatus: String = "working"
  ) throws -> DashboardConversationRecord {
    let codexModeJSON = codexIntegrationMode.map { #""codex_integration_mode":"\#($0)","# } ?? ""
    let claudeModeJSON = claudeIntegrationMode.map { #""claude_integration_mode":"\#($0)","# } ?? ""

    let json = """
    {
      "session_id": "session-1",
      "provider": "\(provider)",
      "project_path": "/tmp/orbitdock",
      "project_name": "OrbitDock",
      "repository_root": "/tmp/orbitdock",
      "git_branch": "main",
      "is_worktree": false,
      "worktree_id": null,
      "model": "gpt-5",
      \(codexModeJSON)
      \(claudeModeJSON)
      "status": "\(status)",
      "work_status": "\(workStatus)",
      "control_mode": "direct",
      "lifecycle_state": "open",
      "list_status": "\(listStatus)",
      "display_title": "Dashboard Session",
      "context_line": "Investigate dashboard controls",
      "last_message": "Working through the UI",
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
    let decoder = JSONDecoder()
    let item = try decoder.decode(ServerDashboardConversationItem.self, from: data)
    return DashboardConversationRecord(
      item: item,
      endpointId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      endpointName: "Preview Server"
    )
  }
}
