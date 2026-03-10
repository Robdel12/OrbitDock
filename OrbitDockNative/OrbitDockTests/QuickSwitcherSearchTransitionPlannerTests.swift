import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct QuickSwitcherSearchTransitionPlannerTests {
  @Test func enteringSearchCapturesSelectedSessionAndResetsSelectionState() {
    let sessions = [makeSession(id: "one"), makeSession(id: "two")]

    let transition = QuickSwitcherSearchTransitionPlanner.transition(
      oldSearchText: "",
      newSearchText: "rename",
      previousMode: .standard,
      selectedKind: .session(index: 1),
      visibleSessions: sessions
    )

    #expect(transition.targetSession?.id == "two")
    #expect(transition.selectedIndex == 0)
    #expect(transition.hoveredIndex == nil)
    #expect(transition.mode == .standard)
    #expect(transition.shouldLoadRecentProjects == false)
  }

  @Test func clearingSearchDropsCapturedTargetAndReturnsToStandardMode() {
    let transition = QuickSwitcherSearchTransitionPlanner.transition(
      oldSearchText: "new claude",
      newSearchText: "",
      previousMode: .quickLaunch(.claude),
      selectedKind: .quickLaunchProject(index: 0),
      visibleSessions: [makeSession(id: "one")]
    )

    #expect(transition.targetSession == nil)
    #expect(transition.mode == .standard)
    #expect(transition.shouldLoadRecentProjects == false)
  }

  @Test func enteringQuickLaunchRequestsRecentProjectLoadOnce() {
    let transition = QuickSwitcherSearchTransitionPlanner.transition(
      oldSearchText: "rename",
      newSearchText: "new claude",
      previousMode: .standard,
      selectedKind: .none,
      visibleSessions: [makeSession(id: "one")]
    )

    #expect(transition.mode == .quickLaunch(.claude))
    #expect(transition.shouldLoadRecentProjects == true)
  }

  @Test func stayingInQuickLaunchDoesNotReloadProjects() {
    let transition = QuickSwitcherSearchTransitionPlanner.transition(
      oldSearchText: "new c",
      newSearchText: "new claude printer",
      previousMode: .quickLaunch(.claude),
      selectedKind: .quickLaunchProject(index: 0),
      visibleSessions: [makeSession(id: "one")]
    )

    #expect(transition.mode == .quickLaunch(.claude))
    #expect(transition.shouldLoadRecentProjects == false)
  }

  private func makeSession(id: String) -> Session {
    Session(
      id: id,
      projectPath: "/tmp/\(id)",
      status: .active,
      workStatus: .waiting,
      totalTokens: 0,
      totalCostUSD: 0
    )
  }
}
