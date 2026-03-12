import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionRegistryTests {
  @Test func applyingRootEventsBuildsWarmSummaryState() async throws {
    let registry = SessionRegistry()
    let endpointId = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))

    let changed = await registry.apply(
      .sessionsList(
        endpointId: endpointId,
        endpointName: "Alpha",
        connectionStatus: .connected,
        sessions: [
          makeListItem(id: "session-a", workStatus: .working),
          makeListItem(id: "session-b", workStatus: .reply),
        ]
      )
    )

    let snapshot = await registry.snapshot()

    #expect(changed)
    #expect(snapshot.state.counts.total == 2)
    #expect(snapshot.state.counts.working == 1)
    #expect(snapshot.records.count == 2)
    #expect(snapshot.hotSessionIDs.isEmpty)
  }

  @Test func promotingAndDemotingOnlyAffectsTargetHotSession() async throws {
    let registry = SessionRegistry()
    let endpointId = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
    let hot = ScopedSessionID(endpointId: endpointId, sessionId: "session-hot")
    let warm = ScopedSessionID(endpointId: endpointId, sessionId: "session-warm")

    _ = await registry.apply(
      .sessionsList(
        endpointId: endpointId,
        endpointName: "Beta",
        connectionStatus: .connected,
        sessions: [
          makeListItem(id: hot.sessionId, workStatus: .working),
          makeListItem(id: warm.sessionId, workStatus: .reply),
        ]
      )
    )

    await registry.promote(hot)

    #expect(await registry.isHot(hot))
    #expect(!(await registry.isHot(warm)))

    await registry.demote(hot)

    let snapshot = await registry.snapshot()
    #expect(snapshot.hotSessionIDs.isEmpty)
    #expect(snapshot.records.count == 2)
  }
}

private func makeListItem(
  id: String,
  workStatus: ServerWorkStatus,
  pendingToolName: String? = nil
) -> ServerSessionListItem {
  ServerSessionListItem(
    id: id,
    provider: .codex,
    projectPath: "/tmp/\(id)",
    projectName: "OrbitDock",
    gitBranch: "main",
    model: "gpt-5.4",
    status: .active,
    workStatus: workStatus,
    codexIntegrationMode: .passive,
    claudeIntegrationMode: nil,
    startedAt: "2026-03-11T10:00:00Z",
    lastActivityAt: "2026-03-11T10:05:00Z",
    unreadCount: 0,
    pendingToolName: pendingToolName,
    repositoryRoot: "/tmp",
    isWorktree: false,
    worktreeId: nil,
    totalTokens: 42,
    totalCostUSD: 0.0,
    displayTitle: "OrbitDock",
    displayTitleSortKey: "orbitdock",
    displaySearchText: "OrbitDock main",
    contextLine: "Context",
    listStatus: nil,
    effort: nil
  )
}
