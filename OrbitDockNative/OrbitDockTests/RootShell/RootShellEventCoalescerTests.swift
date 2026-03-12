import Foundation
@testable import OrbitDock
import Testing

struct RootShellEventCoalescerTests {
  @Test func coalescesRepeatedSessionUpdatesDownToLatestState() {
    let endpointId = rootShellTestEndpointID
    let session1 = makeListItem(id: "session-1", title: "First", unreadCount: 1)
    let session1Updated = makeListItem(id: "session-1", title: "First Updated", unreadCount: 3)
    let session2 = makeListItem(id: "session-2", title: "Second", unreadCount: 0)

    let events: [RootShellEvent] = [
      .sessionCreated(endpointId: endpointId, endpointName: "Primary", connectionStatus: .connected, session: session1),
      .sessionUpdated(endpointId: endpointId, endpointName: "Primary", connectionStatus: .connected, session: session1Updated),
      .sessionCreated(endpointId: endpointId, endpointName: "Primary", connectionStatus: .connected, session: session2),
      .sessionRemoved(endpointId: endpointId, sessionId: "session-2"),
    ]

    let coalesced = RootShellEventCoalescer.coalesce(events)

    #expect(coalesced.count == 2)
    guard case let .sessionUpdated(_, _, _, finalSession)? = coalesced.first else {
      Issue.record("Expected a final session update for session-1")
      return
    }
    #expect(finalSession.id == "session-1")
    #expect(finalSession.displayTitle == "First Updated")
    #expect(finalSession.unreadCount == 3)
    guard case let .sessionRemoved(_, removedId)? = coalesced.last else {
      Issue.record("Expected the last session event to be a removal")
      return
    }
    #expect(removedId == "session-2")
  }

  @Test func keepsLatestSessionsListAndLaterEndpointUpdate() {
    let endpointId = rootShellTestEndpointID
    let bootstrap = makeListItem(id: "session-1", title: "Bootstrap", unreadCount: 0)
    let later = makeListItem(id: "session-1", title: "Live", unreadCount: 2)

    let coalesced = RootShellEventCoalescer.coalesce([
      .sessionsList(
        endpointId: endpointId,
        endpointName: "Primary",
        connectionStatus: .connecting,
        sessions: [bootstrap]
      ),
      .sessionUpdated(
        endpointId: endpointId,
        endpointName: "Primary",
        connectionStatus: .connected,
        session: later
      ),
      .endpointConnectionChanged(
        endpointId: endpointId,
        endpointName: "Primary",
        connectionStatus: .connected
      ),
    ])

    #expect(coalesced.count == 3)
    guard case let .sessionsList(_, _, bootstrapStatus, sessions)? = coalesced.first else {
      Issue.record("Expected initial sessions list bootstrap")
      return
    }
    #expect(bootstrapStatus == .connecting)
    #expect(sessions.first?.displayTitle == "Bootstrap")
    guard case let .sessionUpdated(_, _, liveStatus, liveSession)? = coalesced.dropFirst().first else {
      Issue.record("Expected a later live session update")
      return
    }
    #expect(liveStatus == .connected)
    #expect(liveSession.displayTitle == "Live")
    guard case let .endpointConnectionChanged(_, _, connectionStatus)? = coalesced.last else {
      Issue.record("Expected endpoint connection change to survive")
      return
    }
    #expect(connectionStatus == .connected)
  }
}

private extension RootShellEventCoalescerTests {
  func makeListItem(id: String, title: String, unreadCount: UInt64) -> ServerSessionListItem {
    ServerSessionListItem(
      id: id,
      provider: .codex,
      projectPath: "/tmp/\(id)",
      projectName: "OrbitDock",
      gitBranch: "main",
      model: "gpt-5.4",
      status: .active,
      workStatus: .reply,
      codexIntegrationMode: .passive,
      claudeIntegrationMode: nil,
      startedAt: "2026-03-11T01:00:00Z",
      lastActivityAt: "2026-03-11T02:00:00Z",
      unreadCount: unreadCount,
      hasTurnDiff: false,
      pendingToolName: nil,
      repositoryRoot: "/tmp",
      isWorktree: false,
      worktreeId: nil,
      totalTokens: 0,
      totalCostUSD: 0,
      displayTitle: title,
      displayTitleSortKey: title.lowercased(),
      displaySearchText: title.lowercased(),
      contextLine: nil,
      listStatus: nil,
      effort: nil
    )
  }
}
