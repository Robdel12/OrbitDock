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

    let before = state.recordsByScopedID[ScopedSessionID(endpointId: endpointId, sessionId: "sess-b").scopedID]

    let changed = RootShellReducer.reduce(
      state: &state,
      event: .sessionUpdated(
        endpointId: endpointId,
        endpointName: "Beta",
        connectionStatus: .connected,
        session: makeListItem(id: "sess-a", workStatus: .permission, pendingToolName: "Bash")
      )
    )

    let updated = state.recordsByScopedID[ScopedSessionID(endpointId: endpointId, sessionId: "sess-a").scopedID]
    let untouched = state.recordsByScopedID[ScopedSessionID(endpointId: endpointId, sessionId: "sess-b").scopedID]

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

    let record = state.recordsByScopedID[ScopedSessionID(endpointId: endpointId, sessionId: "sess-ended").scopedID]
    #expect(changed)
    #expect(record?.status == .ended)
    #expect(record?.displayStatus == .ended)
    #expect(record?.isActive == false)
  }

  @Test func sessionRemovedDropsRecordFromRootState() throws {
    var state = RootShellState()
    let endpointId = try #require(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))

    _ = RootShellReducer.reduce(
      state: &state,
      event: .sessionsList(
        endpointId: endpointId,
        endpointName: "Epsilon",
        connectionStatus: .connected,
        sessions: [
          makeListItem(id: "sess-a", workStatus: .reply),
          makeListItem(id: "sess-b", workStatus: .working, codexIntegrationMode: .direct),
        ]
      )
    )

    let changed = RootShellReducer.reduce(
      state: &state,
      event: .sessionRemoved(endpointId: endpointId, sessionId: "sess-a")
    )

    #expect(changed)
    #expect(state.recordsByScopedID.count == 1)
    let remainingScopedIDs = Set(state.recordsByScopedID.keys.map { $0 })
    let expectedScopedIDs: Set<String> = [ScopedSessionID(endpointId: endpointId, sessionId: "sess-b").scopedID]
    #expect(remainingScopedIDs == expectedScopedIDs)
    #expect(state.counts.total == 1)
    #expect(state.missionControlRecords.map(\.sessionId) == ["sess-b"])
  }

  @Test func derivedSlicesSeparateMissionControlFromRecentRecords() throws {
    var state = RootShellState()
    let endpointId = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))

    _ = RootShellReducer.reduce(
      state: &state,
      event: .sessionsList(
        endpointId: endpointId,
        endpointName: "Delta",
        connectionStatus: .connected,
        sessions: [
          makeListItem(
            id: "direct-working",
            workStatus: .working,
            codexIntegrationMode: .direct,
            lastActivityAt: "2026-03-11T10:06:00Z"
          ),
          makeListItem(
            id: "passive-recent",
            workStatus: .reply,
            codexIntegrationMode: .passive,
            lastActivityAt: "2026-03-11T10:07:00Z"
          ),
        ]
      )
    )

    #expect(state.missionControlRecords.map(\.sessionId) == ["direct-working"])
    #expect(state.recentRecords.prefix(1).map(\.sessionId) == ["passive-recent"])
  }
}

private func makeListItem(
  id: String,
  workStatus: ServerWorkStatus,
  pendingToolName: String? = nil,
  codexIntegrationMode: ServerCodexIntegrationMode = .passive,
  lastActivityAt: String = "2026-03-11T10:05:00Z"
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
    codexIntegrationMode: codexIntegrationMode,
    claudeIntegrationMode: nil,
    startedAt: "2026-03-11T10:00:00Z",
    lastActivityAt: lastActivityAt,
    unreadCount: 0,
    hasTurnDiff: false,
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
