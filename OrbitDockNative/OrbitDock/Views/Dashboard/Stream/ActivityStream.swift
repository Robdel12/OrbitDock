//
//  ActivityStream.swift
//  OrbitDock
//
//  Pure grouping and sorting for the live mission control stream.
//

import Foundation

struct ActivityStream {
  let attention: [Session]
  let working: [Session]
  let ready: [Session]
  let ended: [Session]

  static func build(
    from sessions: [Session],
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort,
    providerFilter: ActiveSessionProviderFilter,
    projectFilter: String? = nil
  ) -> ActivityStream {
    var activeSessions = sessions.filter(\.showsInMissionControl)

    switch providerFilter {
      case .all: break
      case .claude: activeSessions = activeSessions.filter { $0.provider == .claude }
      case .codex: activeSessions = activeSessions.filter { $0.provider == .codex }
    }

    if let projectFilter {
      activeSessions = activeSessions.filter { $0.projectPath == projectFilter }
    }

    let filtered: [Session]
    switch filter {
      case .all: filtered = activeSessions
      case .direct: filtered = activeSessions.filter(\.isDirect)
      case .attention: filtered = activeSessions.filter { SessionDisplayStatus.from($0).needsAttention }
      case .running: filtered = activeSessions.filter { SessionDisplayStatus.from($0) == .working }
      case .ready: filtered = activeSessions.filter { SessionDisplayStatus.from($0) == .reply }
    }

    let attentionSessions = filtered.filter { SessionDisplayStatus.from($0).needsAttention }
      .sorted { lhs, rhs in
        sortDate(lhs) < sortDate(rhs)
      }

    let workingSessions = filtered.filter { SessionDisplayStatus.from($0) == .working }
      .sorted { lhs, rhs in sortSessions(lhs: lhs, rhs: rhs, sort: sort) }

    let readySessions = filtered.filter {
      let status = SessionDisplayStatus.from($0)
      return !status.needsAttention && status != .working
    }
    .sorted { lhs, rhs in sortSessions(lhs: lhs, rhs: rhs, sort: sort) }

    return ActivityStream(
      attention: attentionSessions,
      working: workingSessions,
      ready: readySessions,
      ended: sessions.filter { !$0.isActive }
    )
  }

  private static func sortSessions(lhs: Session, rhs: Session, sort: ActiveSessionSort) -> Bool {
    switch sort {
      case .recent:
        return sortDate(lhs) > sortDate(rhs)
      case .name:
        let lhsName = lhs.displayName
        let rhsName = rhs.displayName
        let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return sortDate(lhs) > sortDate(rhs)
      case .status:
        let lhsPriority = statusPriority(SessionDisplayStatus.from(lhs))
        let rhsPriority = statusPriority(SessionDisplayStatus.from(rhs))
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return sortDate(lhs) > sortDate(rhs)
      case .tokens:
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return sortDate(lhs) > sortDate(rhs)
      case .cost:
        if lhs.totalCostUSD != rhs.totalCostUSD { return lhs.totalCostUSD > rhs.totalCostUSD }
        return sortDate(lhs) > sortDate(rhs)
    }
  }

  private static func sortDate(_ session: Session) -> Date {
    session.lastActivityAt ?? session.startedAt ?? .distantPast
  }

  private static func statusPriority(_ status: SessionDisplayStatus) -> Int {
    switch status {
      case .permission: 0
      case .question: 1
      case .working: 2
      case .reply: 3
      case .ended: 4
    }
  }
}
