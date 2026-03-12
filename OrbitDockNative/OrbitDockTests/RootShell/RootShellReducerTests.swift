import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct RootShellReducerTests {
  @Test func sessionsListSeedsNormalizedRecordsAndCounts() throws {
    var state = RootShellState()
    let endpointId = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))

    let changed = RootShellReducer.reduce(
      state: &state,
      event: .sessionsList(
        endpointId: endpointId,
        endpointName: "Alpha",
        connectionStatus: .connected,
        sessions: [
          makeListItem(id: "active-1", workStatus: .working),
          makeListItem(id: "reply-1", workStatus: .reply),
        ]
      )
    )

    #expect(changed)
    #expect(state.recordsByScopedID.count == 2)
    #expect(state.counts.total == 2)
    #expect(state.counts.active == 2)
    #expect(state.counts.working == 1)
    #expect(state.counts.ready == 1)
  }

  @Test func sessionUpdatedOnlyChangesTargetRecord() throws {
    var state = RootShellState()
    let endpointId = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

    _ = RootShellReducer.reduce(
      state: &state,
      event: .sessionsList(
        endpointId: endpointId,
        endpointName: "Beta",
        connectionStatus: .connected,
        sessions: [
          makeListItem(id: "sess-a", workStatus: .working, pendingToolName: nil),
          makeListItem(id: "sess-b", workStatus: .reply, pendingToolName: nil),
        ]
      )
    )

    let before = state.recordsByScopedID[ScopedSessionID(endpointId: endpointId, sessionId: "sess-b")]

    let changed = RootShellReducer.reduce(
      state: &state,
      event: .sessionUpdated(
        endpointId: endpointId,
        endpointName: "Beta",
        connectionStatus: .connected,
        session: makeListItem(id: "sess-a", workStatus: .permission, pendingToolName: "Bash")
      )
    )

    let updated = state.recordsByScopedID[ScopedSessionID(endpointId: endpointId, sessionId: "sess-a")]
    let untouched = state.recordsByScopedID[ScopedSessionID(endpointId: endpointId, sessionId: "sess-b")]

    #expect(changed)
    #expect(updated?.displayStatus == .permission)
    #expect(updated?.pendingToolName == "Bash")
    #expect(untouched == before)
  }

  @Test func identicalSessionUpdateIsIgnored() throws {
    var state = RootShellState()
    let endpointId = try #require(UUID(uuidString: "2A2A2A2A-2222-2222-2222-222222222222"))

    let baseline = makeListItem(id: "sess-a", workStatus: .reply, pendingToolName: nil)
    _ = RootShellReducer.reduce(
      state: &state,
      event: .sessionsList(
        endpointId: endpointId,
        endpointName: "Beta",
        connectionStatus: .connected,
        sessions: [baseline]
      )
    )

    let changed = RootShellReducer.reduce(
      state: &state,
      event: .sessionUpdated(
        endpointId: endpointId,
        endpointName: "Beta",
        connectionStatus: .connected,
        session: baseline
      )
    )

    #expect(!changed)
  }

  @Test func sessionEndedMarksExistingRecordEndedWithoutRemovingIt() throws {
    var state = RootShellState()
    let endpointId = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))

    _ = RootShellReducer.reduce(
      state: &state,
      event: .sessionsList(
        endpointId: endpointId,
        endpointName: "Gamma",
        connectionStatus: .connected,
        sessions: [makeListItem(id: "sess-ended", workStatus: .working)]
      )
    )

    let changed = RootShellReducer.reduce(
      state: &state,
      event: .sessionEnded(endpointId: endpointId, sessionId: "sess-ended", reason: "finished")
    )

    let record = state.recordsByScopedID[ScopedSessionID(endpointId: endpointId, sessionId: "sess-ended")]
    #expect(changed)
    #expect(record?.status == .ended)
    #expect(record?.displayStatus == .ended)
    #expect(record?.isActive == false)
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
