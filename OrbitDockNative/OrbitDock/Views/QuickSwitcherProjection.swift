import Foundation

struct QuickSwitcherProjection: Equatable, Sendable {
  let filteredSessions: [Session]
  let activeSessions: [Session]
  let recentSessions: [Session]
  let allVisibleSessions: [Session]
  let shouldShowRecentSessions: Bool
  let commandCount: Int
  let dashboardIndex: Int
  let sessionStartIndex: Int
  let totalItems: Int

  static func make(
    sessions: [Session],
    normalizedQuery: String,
    isRecentExpanded: Bool,
    commandCount: Int,
    quickLaunchProjectCount: Int? = nil
  ) -> QuickSwitcherProjection {
    let filteredSessions = filterSessions(sessions, normalizedQuery: normalizedQuery)
    let activeSessions = filteredSessions
      .filter(\.showsInMissionControl)
      .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }

    let recentSessions = Array(
      filteredSessions
        .filter { !$0.showsInMissionControl }
        .sorted { recentSessionDate(for: $0) > recentSessionDate(for: $1) }
        .prefix(20)
    )

    let shouldShowRecentSessions = !normalizedQuery.isEmpty || isRecentExpanded
    let allVisibleSessions = shouldShowRecentSessions ? activeSessions + recentSessions : activeSessions
    let dashboardIndex = commandCount
    let sessionStartIndex = commandCount + 1
    let totalItems = quickLaunchProjectCount ?? (commandCount + 1 + allVisibleSessions.count)

    return QuickSwitcherProjection(
      filteredSessions: filteredSessions,
      activeSessions: activeSessions,
      recentSessions: recentSessions,
      allVisibleSessions: allVisibleSessions,
      shouldShowRecentSessions: shouldShowRecentSessions,
      commandCount: commandCount,
      dashboardIndex: dashboardIndex,
      sessionStartIndex: sessionStartIndex,
      totalItems: totalItems
    )
  }

  private static func filterSessions(_ sessions: [Session], normalizedQuery: String) -> [Session] {
    guard !normalizedQuery.isEmpty else { return sessions }

    return sessions.filter { session in
      matches(session.id, query: normalizedQuery)
        || matches(session.displayName, query: normalizedQuery)
        || matches(session.projectPath, query: normalizedQuery)
        || matches(session.summary, query: normalizedQuery)
        || matches(session.customName, query: normalizedQuery)
        || matches(session.branch, query: normalizedQuery)
    }
  }

  private static func matches(_ value: String?, query: String) -> Bool {
    guard let value else { return false }
    return value.localizedCaseInsensitiveContains(query)
  }

  private static func recentSessionDate(for session: Session) -> Date {
    session.lastActivityAt ?? session.endedAt ?? session.startedAt ?? .distantPast
  }
}
