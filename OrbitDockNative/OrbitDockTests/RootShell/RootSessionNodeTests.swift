import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct RootSessionNodeTests {
  @Test func listItemAdapterPrecomputesFallbackDisplayAndSearchFields() throws {
    let endpointId = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))

    let item = ServerSessionListItem(
      id: "session-1",
      provider: .codex,
      projectPath: "/tmp/orbitdock",
      projectName: "OrbitDock",
      gitBranch: "main",
      model: "gpt-5.4",
      status: .active,
      workStatus: .reply,
      controlMode: .passive,
      lifecycleState: .open,
      steerable: false,
      codexIntegrationMode: .passive,
      claudeIntegrationMode: nil,
      startedAt: "2026-03-11T01:00:00Z",
      lastActivityAt: "2026-03-11T02:00:00Z",
      unreadCount: 3,
      hasTurnDiff: false,
      pendingToolName: nil,
      repositoryRoot: "/tmp/orbitdock",
      isWorktree: false,
      worktreeId: nil,
      totalTokens: 0,
      totalCostUSD: 0,
      inputTokens: 0,
      outputTokens: 0,
      cachedTokens: 0,
      displayTitle: "OrbitDock",
      displayTitleSortKey: nil,
      displaySearchText: nil,
      contextLine: "<task>Investigate root perf</task>",
      listStatus: .reply,
      summaryRevision: 0,
      effort: nil,
      activeWorkerCount: 0,
      pendingToolFamily: nil,
      forkedFromSessionId: nil,
      missionId: nil,
      issueIdentifier: nil
    )

    let node = RootSessionNode(
      session: item,
      endpointId: endpointId,
      endpointName: "Local",
      connectionStatus: .connected
    )

    #expect(node.id == "11111111-1111-1111-1111-111111111111::session-1")
    #expect(node.displayTitle == "OrbitDock")
    #expect(node.displayTitleSortKey == "orbitdock")
    #expect(node.displaySearchText.contains("Investigate root perf"))
    #expect(node.listStatus == RootSessionListStatus.reply)
    #expect(node.allowsUserNotifications == false)
  }

  @Test func listItemAdapterUsesServerAuthoredRootFieldsWhenPresent() throws {
    let endpointId = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

    let item = ServerSessionListItem(
      id: "session-2",
      provider: .claude,
      projectPath: "/tmp/project",
      projectName: "Project",
      gitBranch: "feature/root-rewrite",
      model: "claude-sonnet-4",
      status: .active,
      workStatus: .working,
      controlMode: .direct,
      lifecycleState: .open,
      steerable: false,
      codexIntegrationMode: nil,
      claudeIntegrationMode: .direct,
      startedAt: "2026-03-11T01:00:00Z",
      lastActivityAt: "2026-03-11T02:00:00Z",
      unreadCount: 1,
      hasTurnDiff: false,
      pendingToolName: nil,
      repositoryRoot: "/tmp/project",
      isWorktree: true,
      worktreeId: "wt-1",
      totalTokens: 2_048,
      totalCostUSD: 0,
      inputTokens: 1_024,
      outputTokens: 1_024,
      cachedTokens: 0,
      displayTitle: "Server Title",
      displayTitleSortKey: "server title",
      displaySearchText: "server title feature/root-rewrite claude-sonnet-4",
      contextLine: "Ready for review",
      listStatus: .working,
      summaryRevision: 0,
      effort: nil,
      activeWorkerCount: 0,
      pendingToolFamily: nil,
      forkedFromSessionId: nil,
      missionId: nil,
      issueIdentifier: nil
    )

    let node = RootSessionNode(
      session: item,
      endpointId: endpointId,
      endpointName: "Remote",
      connectionStatus: .connected
    )

    #expect(node.displayTitle == "Server Title")
    #expect(node.displayTitleSortKey == "server title")
    #expect(node.displaySearchText == "server title feature/root-rewrite claude-sonnet-4")
    #expect(node.contextLine == "Ready for review")
    #expect(node.listStatus == RootSessionListStatus.working)
    #expect(node.isWorktree == true)
  }

  @Test func listItemAdapterParsesUnixZLastActivityForRecentOrdering() throws {
    let endpointId = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))

    let item = ServerSessionListItem(
      id: "session-3",
      provider: .codex,
      projectPath: "/tmp/orbitdock",
      projectName: "OrbitDock",
      gitBranch: "main",
      model: "gpt-5.4",
      status: .active,
      workStatus: .waiting,
      controlMode: .direct,
      lifecycleState: .open,
      steerable: false,
      codexIntegrationMode: .direct,
      claudeIntegrationMode: nil,
      startedAt: "2026-03-11T01:00:00Z",
      lastActivityAt: "1773346859Z",
      unreadCount: 26,
      hasTurnDiff: false,
      pendingToolName: nil,
      repositoryRoot: "/tmp/orbitdock",
      isWorktree: false,
      worktreeId: nil,
      totalTokens: 0,
      totalCostUSD: 0,
      inputTokens: 0,
      outputTokens: 0,
      cachedTokens: 0,
      displayTitle: "OrbitDock agent spawn testing",
      displayTitleSortKey: "orbitdock agent spawn testing",
      displaySearchText: "orbitdock agent spawn testing main",
      contextLine: "Latest worker state fix",
      listStatus: .reply,
      summaryRevision: 0,
      effort: nil,
      activeWorkerCount: 0,
      pendingToolFamily: nil,
      forkedFromSessionId: nil,
      missionId: nil,
      issueIdentifier: nil
    )

    let node = RootSessionNode(
      session: item,
      endpointId: endpointId,
      endpointName: "Local",
      connectionStatus: .connected
    )

    #expect(node.lastActivityAt != nil)
    #expect(node.hasUnreadMessages == true)
    #expect(node.isReady == true)
  }

  @Test func parseTimestampAcceptsInternetDateTimeWithoutFractionalSeconds() {
    let timestamp = " 2026-03-11T02:00:00Z "

    let parsedDate = RootSessionNode.parseTimestamp(timestamp)

    #expect(parsedDate != nil)
    #expect(parsedDate?.timeIntervalSince1970 == 1_773_194_400)
  }
}
