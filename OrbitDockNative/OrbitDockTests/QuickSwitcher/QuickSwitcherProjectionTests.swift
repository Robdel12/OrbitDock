import Foundation
@testable import OrbitDock
import Testing

struct QuickSwitcherProjectionTests {
  @Test func filtersSessionsAcrossSearchFields() {
    let sessions = [
      makeSession(
        id: "active-branch",
        projectPath: "/tmp/orbitdock",
        projectName: "OrbitDock",
        branch: "feature/printer",
        summary: "Chat refresh",
        customName: nil,
        status: .active,
        startedAt: Date(timeIntervalSince1970: 100)
      ),
      makeSession(
        id: "recent-summary",
        projectPath: "/tmp/docs",
        projectName: "Docs",
        branch: "main",
        summary: "Printer guidance",
        customName: nil,
        status: .ended,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 20)
      ),
    ]

    let branchProjection = QuickSwitcherProjection.make(
      sessions: sessions,
      normalizedQuery: "printer",
      isRecentExpanded: false,
      commandCount: 0
    )

    #expect(branchProjection.filteredSessions.map(\.sessionId) == ["active-branch", "recent-summary"])
  }

  @Test func filteringIsCaseAndDiacriticInsensitive() {
    let sessions = [
      makeSession(
        id: "accented",
        projectPath: "/tmp/cafe",
        projectName: "Cafe",
        summary: "Café cleanup",
        status: .active,
        startedAt: Date(timeIntervalSince1970: 100)
      ),
    ]

    let projection = QuickSwitcherProjection.make(
      sessions: sessions,
      normalizedQuery: "cafe",
      isRecentExpanded: false,
      commandCount: 0
    )

    #expect(projection.filteredSessions.map(\.sessionId) == ["accented"])
  }

  @Test func activeSessionsSortNewestFirstAndRecentSessionsSortByRecentActivity() {
    let sessions = [
      makeSession(
        id: "active-old",
        status: .active,
        startedAt: Date(timeIntervalSince1970: 50)
      ),
      makeSession(
        id: "active-new",
        status: .active,
        startedAt: Date(timeIntervalSince1970: 100)
      ),
      makeSession(
        id: "recent-older",
        status: .ended,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 40)
      ),
      makeSession(
        id: "recent-newer",
        status: .ended,
        startedAt: Date(timeIntervalSince1970: 20),
        endedAt: Date(timeIntervalSince1970: 30),
        lastActivityAt: Date(timeIntervalSince1970: 90)
      ),
    ]

    let projection = QuickSwitcherProjection.make(
      sessions: sessions,
      normalizedQuery: "",
      isRecentExpanded: true,
      commandCount: 0
    )

    #expect(projection.activeSessions.map(\.sessionId) == ["active-new", "active-old"])
    #expect(projection.recentSessions.map(\.sessionId) == ["recent-newer", "recent-older"])
    #expect(projection.allVisibleSessions.map(\.sessionId) == [
      "active-new",
      "active-old",
      "recent-newer",
      "recent-older",
    ])
  }

  @Test func recentSessionsStayHiddenUntilExpandedUnlessSearching() {
    let sessions = [
      makeSession(
        id: "active",
        projectPath: "/active/project",
        status: .active,
        startedAt: Date(timeIntervalSince1970: 100)
      ),
      makeSession(
        id: "recent",
        projectPath: "/recent/project",
        status: .ended,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 20)
      ),
    ]

    let collapsed = QuickSwitcherProjection.make(
      sessions: sessions,
      normalizedQuery: "",
      isRecentExpanded: false,
      commandCount: 0
    )
    let searching = QuickSwitcherProjection.make(
      sessions: sessions,
      normalizedQuery: "recent",
      isRecentExpanded: false,
      commandCount: 0
    )

    #expect(collapsed.shouldShowRecentSessions == false)
    #expect(collapsed.allVisibleSessions.map(\.sessionId) == ["active"])
    #expect(searching.shouldShowRecentSessions == true)
    #expect(searching.allVisibleSessions.map(\.sessionId) == ["recent"])
  }

  @Test func navigationLayoutUsesCommandDashboardAndVisibleSessionCounts() {
    let sessions = [
      makeSession(id: "active", status: .active, startedAt: Date(timeIntervalSince1970: 100)),
      makeSession(
        id: "recent",
        status: .ended,
        startedAt: Date(timeIntervalSince1970: 10),
        endedAt: Date(timeIntervalSince1970: 20)
      ),
    ]

    let projection = QuickSwitcherProjection.make(
      sessions: sessions,
      normalizedQuery: "",
      isRecentExpanded: true,
      commandCount: 3
    )

    #expect(projection.commandCount == 3)
    #expect(projection.dashboardIndex == 3)
    #expect(projection.sessionStartIndex == 4)
    #expect(projection.totalItems == 6)
  }

  @Test func quickLaunchNavigationUsesProjectCountInsteadOfSessionCounts() {
    let projection = QuickSwitcherProjection.make(
      sessions: [
        makeSession(id: "active", status: .active, startedAt: Date(timeIntervalSince1970: 100)),
      ],
      normalizedQuery: "",
      isRecentExpanded: false,
      commandCount: 2,
      quickLaunchProjectCount: 5
    )

    #expect(projection.totalItems == 5)
    #expect(projection.dashboardIndex == 2)
    #expect(projection.sessionStartIndex == 3)
  }

  @Test func recentSessionsAreCappedAtTwenty() {
    let sessions = (0 ..< 24).map { index in
      makeSession(
        id: "recent-\(index)",
        status: .ended,
        startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        endedAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    let projection = QuickSwitcherProjection.make(
      sessions: sessions,
      normalizedQuery: "",
      isRecentExpanded: true,
      commandCount: 0
    )

    #expect(projection.recentSessions.count == 20)
    #expect(projection.recentSessions.first?.sessionId == "recent-23")
    #expect(projection.recentSessions.last?.sessionId == "recent-4")
  }

  private func makeSession(
    id: String,
    projectPath: String = "/tmp/\(UUID().uuidString)",
    projectName: String? = nil,
    branch: String? = nil,
    summary: String? = nil,
    customName: String? = nil,
    status: Session.SessionStatus,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    lastActivityAt: Date? = nil
  ) -> RootSessionNode {
    var session = Session(
      id: id,
      projectPath: projectPath,
      projectName: projectName,
      branch: branch,
      summary: summary,
      customName: customName,
      status: status,
      workStatus: .waiting,
      startedAt: startedAt,
      endedAt: endedAt,
      totalTokens: 0,
      totalCostUSD: 0,
      lastActivityAt: lastActivityAt
    )
    session.endpointId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    session.endpointName = "Primary"
    session.endpointConnectionStatus = .connected
    return makeRootSessionNode(from: session)
  }
}
