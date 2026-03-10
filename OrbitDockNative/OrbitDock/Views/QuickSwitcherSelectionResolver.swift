import Foundation

enum QuickSwitcherSelectionKind: Equatable {
  case none
  case quickLaunchProject(index: Int)
  case command(index: Int)
  case dashboard
  case session(index: Int)
}

enum QuickSwitcherSelectionResolver {
  static func selectedKind(
    selectedIndex: Int,
    isQuickLaunchMode: Bool,
    quickLaunchProjectCount: Int,
    commandCount: Int,
    dashboardIndex: Int,
    sessionStartIndex: Int,
    visibleSessionCount: Int
  ) -> QuickSwitcherSelectionKind {
    if isQuickLaunchMode {
      guard selectedIndex >= 0, selectedIndex < quickLaunchProjectCount else { return .none }
      return .quickLaunchProject(index: selectedIndex)
    }

    if selectedIndex >= 0, selectedIndex < commandCount {
      return .command(index: selectedIndex)
    }

    if selectedIndex == dashboardIndex {
      return .dashboard
    }

    let sessionIndex = selectedIndex - sessionStartIndex
    guard sessionIndex >= 0, sessionIndex < visibleSessionCount else { return .none }
    return .session(index: sessionIndex)
  }

  static func commandTargetSession(
    currentSession: Session?,
    explicitTargetSession: Session?,
    fallbackVisibleSession: Session?
  ) -> Session? {
    currentSession ?? explicitTargetSession ?? fallbackVisibleSession
  }
}
