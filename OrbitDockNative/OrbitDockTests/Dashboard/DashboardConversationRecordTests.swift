import Foundation
@testable import OrbitDock
import Testing

@MainActor
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

  @Test func activeWorkingConversationUsesWorkingStatusEvenWhenListStatusLags() throws {
    let record = try makeRecord(
      provider: "codex",
      listStatus: "ended",
      status: "active",
      workStatus: "working"
    )

    #expect(record.displayStatus == .working)
    #expect(record.canEnd == true)
  }

  @Test func activeReplyConversationDoesNotRenderAsEndedWhenListStatusLags() throws {
    let record = try makeRecord(
      provider: "claude",
      listStatus: "ended",
      status: "active",
      workStatus: "reply"
    )

    #expect(record.displayStatus == .reply)
    #expect(record.canEnd == true)
  }

  @Test func displayProjectNamePrefersCanonicalProjectNameOverGroupingName() throws {
    let json = """
    {
      "session_id": "session-grouping",
      "provider": "codex",
      "project_path": "/tmp/orbitdock/worktrees/feature-a",
      "grouping_path": "/tmp/orbitdock",
      "grouping_name": "feature-a",
      "project_name": "OrbitDock",
      "repository_root": "/tmp/orbitdock",
      "git_branch": "feature-a",
      "is_worktree": true,
      "worktree_id": "wt-feature-a",
      "model": "gpt-5",
      "codex_integration_mode": "passive",
      "status": "active",
      "work_status": "working",
      "control_mode": "passive",
      "lifecycle_state": "open",
      "list_status": "working",
      "display_title": "Feature A",
      "context_line": "Implement dashboard grouping",
      "last_message": "WIP",
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
      "effort": null
    }
    """

    let data = try #require(json.data(using: .utf8))
    let item = try JSONDecoder().decode(ServerDashboardConversationItem.self, from: data)
    let record = DashboardConversationRecord(
      item: item,
      endpointId: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
      endpointName: "Preview Server"
    )

    #expect(record.groupingPath == "/tmp/orbitdock")
    #expect(record.displayProjectName == "OrbitDock")
  }

  @Test func listItemUpdateRecomputesGroupingFromRepositoryRoot() throws {
    let json = """
    {
      "session_id": "session-worktree",
      "provider": "codex",
      "project_path": "/tmp/orbitdock/worktrees/old",
      "grouping_path": "/tmp/orbitdock/worktrees/old",
      "grouping_name": "old",
      "project_name": null,
      "repository_root": null,
      "git_branch": "feature-old",
      "is_worktree": true,
      "worktree_id": "wt-old",
      "model": "gpt-5",
      "codex_integration_mode": "passive",
      "status": "active",
      "work_status": "working",
      "control_mode": "passive",
      "lifecycle_state": "open",
      "list_status": "working",
      "display_title": "Old Worktree",
      "context_line": "WIP",
      "last_message": "Working",
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
      "effort": null
    }
    """

    let data = try #require(json.data(using: .utf8))
    let dashboardItem = try JSONDecoder().decode(ServerDashboardConversationItem.self, from: data)
    let original = DashboardConversationRecord(
      item: dashboardItem,
      endpointId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      endpointName: "Preview Server"
    )
    let listUpdate = makeListItem(
      projectPath: "/tmp/orbitdock/worktrees/new",
      projectName: "OrbitDock",
      repositoryRoot: "/tmp/orbitdock",
      gitBranch: "feature-new",
      isWorktree: true,
      worktreeId: "wt-new"
    )
    let updated = original.applyingListItemUpdate(listUpdate, endpointName: nil)

    #expect(updated.groupingPath == "/tmp/orbitdock")
    #expect(updated.displayProjectName == "OrbitDock")
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

  private func makeListItem(
    projectPath: String,
    projectName: String?,
    repositoryRoot: String?,
    gitBranch: String?,
    isWorktree: Bool,
    worktreeId: String?
  ) -> ServerSessionListItem {
    ServerSessionListItem(
      id: "session-worktree",
      provider: .codex,
      projectPath: projectPath,
      projectName: projectName,
      gitBranch: gitBranch,
      model: "gpt-5",
      status: .active,
      workStatus: .working,
      controlMode: .passive,
      lifecycleState: .open,
      steerable: false,
      codexIntegrationMode: .passive,
      claudeIntegrationMode: nil,
      startedAt: "2026-03-20T10:00:00Z",
      lastActivityAt: "2026-03-20T11:00:00Z",
      unreadCount: 0,
      hasTurnDiff: false,
      pendingToolName: nil,
      repositoryRoot: repositoryRoot,
      isWorktree: isWorktree,
      worktreeId: worktreeId,
      totalTokens: 0,
      totalCostUSD: 0,
      inputTokens: 0,
      outputTokens: 0,
      cachedTokens: 0,
      displayTitle: "Updated Worktree",
      displayTitleSortKey: nil,
      displaySearchText: nil,
      contextLine: "Updated context",
      listStatus: .working,
      summaryRevision: 1,
      effort: nil,
      activeWorkerCount: 0,
      pendingToolFamily: nil,
      forkedFromSessionId: nil,
      missionId: nil,
      issueIdentifier: nil
    )
  }
}
