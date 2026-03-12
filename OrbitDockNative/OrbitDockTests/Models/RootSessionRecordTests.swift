import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct RootSessionRecordTests {

  @Test func summaryAdapterPrecomputesDisplayAndSearchFields() {
    let summary = ServerSessionSummary(
      id: "session-1",
      provider: .codex,
      projectPath: "/tmp/orbitdock",
      transcriptPath: nil,
      projectName: "OrbitDock",
      model: "gpt-5.4",
      customName: nil,
      summary: "<task>Investigate root perf</task>",
      status: .active,
      workStatus: .waiting,
      tokenUsage: nil,
      tokenUsageSnapshotKind: nil,
      hasPendingApproval: false,
      codexIntegrationMode: .passive,
      claudeIntegrationMode: nil,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: nil,
      collaborationMode: nil,
      multiAgent: nil,
      personality: nil,
      serviceTier: nil,
      developerInstructions: nil,
      pendingToolName: nil,
      pendingToolInput: nil,
      pendingQuestion: nil,
      pendingApprovalId: nil,
      startedAt: "2026-03-11T01:00:00Z",
      lastActivityAt: "2026-03-11T02:00:00Z",
      gitBranch: "main",
      gitSha: nil,
      currentCwd: nil,
      firstPrompt: "Profile the root session list",
      lastMessage: "Found a hot path in displayName",
      effort: "medium",
      approvalVersion: nil,
      repositoryRoot: "/tmp/orbitdock",
      isWorktree: false,
      worktreeId: nil,
      unreadCount: 3,
      displayTitle: nil,
      displayTitleSortKey: nil,
      displaySearchText: nil,
      contextLine: nil,
      listStatus: nil
    )

    let record = summary.toRootSessionRecord(
      endpointId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      endpointName: "Local",
      endpointConnectionStatus: ConnectionStatus.connected
    )

    #expect(record.id == "11111111-1111-1111-1111-111111111111::session-1")
    #expect(record.displayTitle == "Investigate root perf")
    #expect(record.displayTitleSortKey == "investigate root perf")
    #expect(record.displaySearchText.contains("Found a hot path in displayName"))
    #expect(record.listStatus == RootSessionListStatus.reply)
    #expect(record.allowsUserNotifications == false)
  }

  @Test func listItemAdapterUsesServerAuthoredRootFieldsWhenPresent() {
    let item = ServerSessionListItem(
      id: "session-2",
      provider: .claude,
      projectPath: "/tmp/project",
      projectName: "Project",
      gitBranch: "feature/root-rewrite",
      model: "claude-sonnet-4",
      status: .active,
      workStatus: .working,
      codexIntegrationMode: nil,
      claudeIntegrationMode: .direct,
      startedAt: "2026-03-11T01:00:00Z",
      lastActivityAt: "2026-03-11T02:00:00Z",
      unreadCount: 1,
      repositoryRoot: "/tmp/project",
      isWorktree: true,
      worktreeId: "wt-1",
      displayTitle: "Server Title",
      displayTitleSortKey: "server title",
      displaySearchText: "server title feature/root-rewrite claude-sonnet-4",
      contextLine: "Ready for review",
      listStatus: .working,
      effort: nil
    )

    let record = item.toRootSessionRecord(
      endpointId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      endpointName: "Remote",
      endpointConnectionStatus: ConnectionStatus.connected
    )

    #expect(record.displayTitle == "Server Title")
    #expect(record.displayTitleSortKey == "server title")
    #expect(record.displaySearchText == "server title feature/root-rewrite claude-sonnet-4")
    #expect(record.contextLine == "Ready for review")
    #expect(record.listStatus == RootSessionListStatus.working)
    #expect(record.isWorktree == true)
  }
}
