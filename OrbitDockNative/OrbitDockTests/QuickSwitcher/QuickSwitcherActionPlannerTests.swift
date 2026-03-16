import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct QuickSwitcherActionPlannerTests {
  @Test func capturedTargetSessionUsesSelectedSessionWhenSearchStarts() {
    let sessions = [
      makeSession(id: "one"),
      makeSession(id: "two"),
    ]

    let target = QuickSwitcherActionPlanner.capturedTargetSession(
      oldSearchText: "",
      newSearchText: "rea",
      selectedKind: .session(index: 1),
      visibleSessions: sessions
    )

    #expect(target?.sessionId == "two")
  }

  @Test func capturedTargetSessionFallsBackToFirstVisibleSession() {
    let sessions = [
      makeSession(id: "one"),
      makeSession(id: "two"),
    ]

    let target = QuickSwitcherActionPlanner.capturedTargetSession(
      oldSearchText: "",
      newSearchText: "rea",
      selectedKind: .dashboard,
      visibleSessions: sessions
    )

    #expect(target?.sessionId == "one")
  }

  @Test func capturedTargetSessionClearsWhenSearchIsReset() {
    let target = QuickSwitcherActionPlanner.capturedTargetSession(
      oldSearchText: "close",
      newSearchText: "",
      selectedKind: .session(index: 0),
      visibleSessions: [makeSession(id: "one")]
    )

    #expect(target == nil)
  }

  @Test func commandPlanUsesCurrentSessionBeforeExplicitTarget() throws {
    let current = makeSession(id: "current")
    let explicit = makeSession(id: "explicit")
    let command = try #require(QuickSwitcherCommandCatalog.sessionCommands().first { $0.id == "copy" })

    let plan = QuickSwitcherActionPlanner.commandPlan(
      command: command,
      currentSession: current,
      explicitTargetSession: explicit,
      fallbackVisibleSession: nil
    )

    #expect(plan == .copyResumeCommand("claude --resume current"))
  }

  @Test func selectionPlanReturnsCommandPlanForSelectedCommand() throws {
    let current = makeSession(id: "current")
    let command = try #require(QuickSwitcherCommandCatalog.sessionCommands().first { $0.id == "finder" })

    let plan = QuickSwitcherActionPlanner.selectionPlan(
      selectedKind: .command(index: 0),
      recentProjects: [],
      filteredCommands: [command],
      visibleSessions: [current],
      currentSession: current,
      explicitTargetSession: nil
    )

    #expect(plan == .command(.openInFinder(path: "/tmp/current")))
  }

  @Test func selectionPlanReturnsNoneWhenSessionCommandHasNoTarget() throws {
    let command = try #require(QuickSwitcherCommandCatalog.sessionCommands().first { $0.id == "rename" })

    let plan = QuickSwitcherActionPlanner.selectionPlan(
      selectedKind: .command(index: 0),
      recentProjects: [],
      filteredCommands: [command],
      visibleSessions: [RootSessionNode](),
      currentSession: nil,
      explicitTargetSession: nil
    )

    #expect(plan == .none)
  }

  @Test func renameTargetSessionUsesSelectedSessionOnly() {
    let sessions = [
      makeSession(id: "one"),
      makeSession(id: "two"),
    ]

    #expect(
      QuickSwitcherActionPlanner.renameTargetSession(
        selectedKind: .session(index: 1),
        visibleSessions: sessions
      )?.sessionId == "two"
    )

    #expect(
      QuickSwitcherActionPlanner.renameTargetSession(
        selectedKind: .dashboard,
        visibleSessions: sessions
      ) == nil
    )
  }

  private func makeSession(id: String) -> RootSessionNode {
    var session = Session(
      id: id,
      projectPath: "/tmp/\(id)",
      status: .active,
      workStatus: .waiting,
      totalTokens: 0,
      totalCostUSD: 0
    )
    session.endpointId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    session.endpointName = "Primary"
    session.endpointConnectionStatus = .connected
    return makeRootSessionNode(from: session)
  }
}
