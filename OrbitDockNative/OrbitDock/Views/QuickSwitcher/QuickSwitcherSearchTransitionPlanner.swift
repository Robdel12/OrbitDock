import Foundation

struct QuickSwitcherSearchTransition: Equatable {
  let targetSession: RootSessionNode?
  let selectedIndex: Int
  let hoveredIndex: Int?
  let mode: QuickSwitcherSearchMode
  let shouldLoadRecentProjects: Bool

}

enum QuickSwitcherSearchTransitionPlanner {
  static func transition(
    oldSearchText: String,
    newSearchText: String,
    previousMode: QuickSwitcherSearchMode,
    selectedKind: QuickSwitcherSelectionKind,
    visibleSessions: [RootSessionNode]
  ) -> QuickSwitcherSearchTransition {
    let nextMode = QuickSwitcherQueryPlanner.plan(searchText: newSearchText).mode
    let targetSession = QuickSwitcherActionPlanner.capturedTargetSession(
      oldSearchText: oldSearchText,
      newSearchText: newSearchText,
      selectedKind: selectedKind,
      visibleSessions: visibleSessions
    )

    return QuickSwitcherSearchTransition(
      targetSession: targetSession,
      selectedIndex: 0,
      hoveredIndex: nil,
      mode: nextMode,
      shouldLoadRecentProjects: !isQuickLaunch(mode: previousMode) && isQuickLaunch(mode: nextMode)
    )
  }

  private static func isQuickLaunch(mode: QuickSwitcherSearchMode) -> Bool {
    if case .quickLaunch = mode {
      return true
    }
    return false
  }
}
