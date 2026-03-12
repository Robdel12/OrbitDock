import Foundation

struct QuickSwitcherProjection: Equatable, Sendable {
  let filteredSessions: [RootSessionRecord]
  let activeSessions: [RootSessionRecord]
  let recentSessions: [RootSessionRecord]
  let allVisibleSessions: [RootSessionRecord]
  let shouldShowRecentSessions: Bool
  let commandCount: Int
  let dashboardIndex: Int
  let sessionStartIndex: Int
  let totalItems: Int

  static func make(
    sessions: [RootSessionRecord],
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

  static func make(
    sessions: [SessionSummary],
    normalizedQuery: String,
    isRecentExpanded: Bool,
    commandCount: Int,
    quickLaunchProjectCount: Int? = nil
  ) -> QuickSwitcherProjection {
    make(
      sessions: sessions.map(RootSessionRecord.init(summary:)),
      normalizedQuery: normalizedQuery,
      isRecentExpanded: isRecentExpanded,
      commandCount: commandCount,
      quickLaunchProjectCount: quickLaunchProjectCount
    )
  }

  private static func filterSessions(_ sessions: [RootSessionRecord], normalizedQuery: String) -> [RootSessionRecord] {
    guard !normalizedQuery.isEmpty else { return sessions }

    return sessions.filter { session in
      matches(session.id, query: normalizedQuery)
        || matches(session.displaySearchText, query: normalizedQuery)
    }
  }

  private static func matches(_ value: String?, query: String) -> Bool {
    guard let value else { return false }
    return normalized(value).contains(normalized(query))
  }

  private static func normalized(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func recentSessionDate(for session: RootSessionRecord) -> Date {
    session.lastActivityAt ?? session.endedAt ?? session.startedAt ?? .distantPast
  }
}
