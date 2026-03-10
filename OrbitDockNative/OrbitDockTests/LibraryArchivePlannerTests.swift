import Foundation
import Testing
@testable import OrbitDock

struct LibraryArchivePlannerTests {
  @Test func stateFiltersByProviderEndpointAndSearchQuery() {
    let endpointA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let endpointB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let sessions = [
      makeSession(
        id: "claude-a",
        endpointId: endpointA,
        endpointName: "Local",
        provider: .claude,
        projectPath: "/tmp/printer",
        firstPrompt: "Fix printer",
        connectionStatus: .connected
      ),
      makeSession(
        id: "codex-a",
        endpointId: endpointA,
        endpointName: "Local",
        provider: .codex,
        projectPath: "/tmp/printer",
        firstPrompt: "Generate STL"
      ),
      makeSession(
        id: "claude-b",
        endpointId: endpointB,
        endpointName: "Remote",
        provider: .claude,
        projectPath: "/tmp/router",
        firstPrompt: "Audit logs"
      ),
    ]

    let state = LibraryArchivePlanner.state(
      sessions: sessions,
      searchText: "printer",
      providerFilter: .claude,
      selectedEndpointId: endpointA,
      sort: .recent
    )

    #expect(state.providerScopedSessions.map(\.id) == ["claude-a", "claude-b"])
    #expect(state.endpointScopedSessions.map(\.id) == ["claude-a"])
    #expect(state.filteredSessions.map(\.id) == ["claude-a"])
    #expect(state.selectedEndpointFacet?.name == "Local")
    #expect(state.scopeDescription == "Local • Claude • 1 sessions")
  }

  @Test func endpointFacetsSortByNameAndTrackConnectionState() {
    let endpointA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let endpointB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let facets = LibraryArchivePlanner.endpointFacets(
      from: [
        makeSession(
          id: "remote",
          endpointId: endpointB,
          endpointName: "zeta remote",
          provider: .claude,
          projectPath: "/tmp/a",
          connectionStatus: .disconnected
        ),
        makeSession(
          id: "local",
          endpointId: endpointA,
          endpointName: "alpha local",
          provider: .codex,
          projectPath: "/tmp/b",
          connectionStatus: .connected
        ),
      ]
    )

    #expect(facets.map(\.name) == ["alpha local", "zeta remote"])
    #expect(facets.map(\.isConnected) == [true, false])
  }

  @Test func projectGroupsSplitLiveAndArchivedSessionsAndSortByRequestedMode() {
    let endpointA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let recent = Date(timeIntervalSince1970: 20)
    let older = Date(timeIntervalSince1970: 10)
    let oldest = Date(timeIntervalSince1970: 5)
    let liveSession = makeSession(
      id: "live-one",
      endpointId: endpointA,
      endpointName: "Local",
      provider: .claude,
      projectPath: "/tmp/printer",
      status: .active,
      workStatus: .working,
      totalTokens: 1_500,
      totalCostUSD: 1.25,
      lastActivityAt: recent,
      connectionStatus: .connected
    )
    let cachedActiveSession = makeSession(
      id: "cached-active",
      endpointId: endpointA,
      endpointName: "Local",
      provider: .claude,
      projectPath: "/tmp/printer",
      status: .active,
      workStatus: .waiting,
      totalTokens: 700,
      totalCostUSD: 0.50,
      lastActivityAt: older,
      connectionStatus: .disconnected
    )
    let archivedSession = makeSession(
      id: "archive",
      endpointId: endpointA,
      endpointName: "Local",
      provider: .codex,
      projectPath: "/tmp/router",
      status: .ended,
      workStatus: .waiting,
      totalTokens: 100,
      totalCostUSD: 0.05,
      lastActivityAt: oldest
    )

    #expect(liveSession.showsInMissionControl)
    #expect(!cachedActiveSession.showsInMissionControl)

    let groups = LibraryArchivePlanner.projectGroups(
      sessions: [liveSession, cachedActiveSession, archivedSession],
      sort: .status
    )

    let firstGroup = try! #require(groups.first)
    #expect(firstGroup.path == "/tmp/printer")
    #expect(firstGroup.liveSessions.map(\.id) == ["live-one"])
    #expect(firstGroup.archivedSessions.map(\.id) == ["cached-active"])
    #expect(firstGroup.cachedActiveSessionCount == 1)
    #expect(firstGroup.totalTokens == 2_200)
    #expect(firstGroup.totalCost == 1.75)
  }

  @Test func liveSessionClassificationRequiresAnActiveLiveConnection() {
    let endpointID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    let live = makeSession(
      id: "live",
      endpointId: endpointID,
      endpointName: "Local",
      provider: .claude,
      projectPath: "/tmp/live",
      status: .active,
      connectionStatus: .connected
    )
    let cached = makeSession(
      id: "cached",
      endpointId: endpointID,
      endpointName: "Local",
      provider: .claude,
      projectPath: "/tmp/live",
      status: .active,
      connectionStatus: .disconnected
    )
    let ended = makeSession(
      id: "ended",
      endpointId: endpointID,
      endpointName: "Local",
      provider: .claude,
      projectPath: "/tmp/live",
      status: .ended,
      connectionStatus: .connected
    )

    #expect(LibraryArchivePlanner.isLiveSession(live))
    #expect(!LibraryArchivePlanner.isLiveSession(cached))
    #expect(!LibraryArchivePlanner.isLiveSession(ended))
  }

  @Test func scopeDescriptionFallsBackToAllServersAndAllProviders() {
    let summary = LibraryArchiveSummary(
      projectCount: 2,
      sessionCount: 7,
      liveCount: 3,
      endpointCount: 1
    )

    let description = LibraryArchivePlanner.scopeDescription(
      summary: summary,
      providerFilter: .all,
      selectedEndpointFacet: nil
    )

    #expect(description == "all servers • all providers • 7 sessions")
  }

  private func makeSession(
    id: String,
    endpointId: UUID,
    endpointName: String,
    provider: Provider,
    projectPath: String,
    firstPrompt: String? = nil,
    status: Session.SessionStatus = .active,
    workStatus: Session.WorkStatus = .waiting,
    totalTokens: Int = 0,
    totalCostUSD: Double = 0,
    lastActivityAt: Date? = nil,
    connectionStatus: ConnectionStatus? = nil
  ) -> Session {
    Session(
      id: id,
      endpointId: endpointId,
      endpointName: endpointName,
      endpointConnectionStatus: connectionStatus,
      projectPath: projectPath,
      projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
      firstPrompt: firstPrompt,
      status: status,
      workStatus: workStatus,
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      lastActivityAt: lastActivityAt,
      provider: provider
    )
  }
}
