import SwiftUI

struct QuickSwitcherViewState {
  let isCompactLayout: Bool
  let currentSession: RootSessionNode?
  let targetSession: RootSessionNode?
  let queryPlan: QuickSwitcherQueryPlan
  let commands: [QuickSwitcherCommand]
  let filteredCommands: [QuickSwitcherCommand]
  let projection: QuickSwitcherProjection
  let quickLaunchMode: QuickLaunchProvider?
  let recentProjects: [ServerRecentProject]

  var searchQuery: String {
    queryPlan.normalizedQuery
  }

  var filteredSessions: [RootSessionNode] {
    projection.filteredSessions
  }

  var activeSessions: [RootSessionNode] {
    projection.activeSessions
  }

  var recentSessions: [RootSessionNode] {
    projection.recentSessions
  }

  var allVisibleSessions: [RootSessionNode] {
    projection.allVisibleSessions
  }

  var totalItems: Int {
    projection.totalItems
  }

  var commandCount: Int {
    projection.commandCount
  }

  var dashboardIndex: Int {
    projection.dashboardIndex
  }

  var sessionStartIndex: Int {
    projection.sessionStartIndex
  }

  var shouldShowRecentSessions: Bool {
    projection.shouldShowRecentSessions
  }

  var isQuickLaunchMode: Bool {
    quickLaunchMode != nil
  }

  var isEmptyState: Bool {
    allVisibleSessions.isEmpty && filteredCommands.isEmpty && !searchQuery.isEmpty
  }

  static func make(
    sessions: [RootSessionNode],
    state: QuickSwitcherState,
    selectedSessionRef: SessionRef?,
    isCompactLayout: Bool
  ) -> QuickSwitcherViewState {
    let currentSession = selectedSessionRef.flatMap { ref in
      sessions.first { $0.sessionRef == ref }
    }
    let targetSession = state.targetSessionScopedID.flatMap { scopedID in
      sessions.first { $0.scopedID == scopedID }
    }

    let queryPlan = QuickSwitcherQueryPlanner.plan(searchText: state.searchText)
    let commands = QuickSwitcherCommandCatalog.allCommands()
    let filteredCommands: [QuickSwitcherCommand] = if queryPlan.normalizedQuery.isEmpty {
      []
    } else {
      commands.filter { $0.name.lowercased().contains(queryPlan.normalizedQuery) }
    }

    let projection = QuickSwitcherProjection.make(
      sessions: sessions,
      normalizedQuery: queryPlan.normalizedQuery,
      isRecentExpanded: state.isRecentExpanded,
      commandCount: filteredCommands.count,
      quickLaunchProjectCount: state.quickLaunchMode != nil ? state.recentProjects.count : nil
    )

    return QuickSwitcherViewState(
      isCompactLayout: isCompactLayout,
      currentSession: currentSession,
      targetSession: targetSession,
      queryPlan: queryPlan,
      commands: commands,
      filteredCommands: filteredCommands,
      projection: projection,
      quickLaunchMode: state.quickLaunchMode,
      recentProjects: state.recentProjects
    )
  }
}
