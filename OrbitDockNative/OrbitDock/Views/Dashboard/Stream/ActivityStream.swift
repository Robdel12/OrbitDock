//
//  ActivityStream.swift
//  OrbitDock
//
//  Pure grouping and sorting for the live mission control stream.
//

import Foundation

struct ActivityStream {
  let attention: [RootSessionNode]
  let working: [RootSessionNode]
  let ready: [RootSessionNode]
  let ended: [RootSessionNode]

  static func build(
    from sessions: [RootSessionNode],
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort,
    providerFilter: ActiveSessionProviderFilter,
    projectFilter: String? = nil
  ) -> ActivityStream {
    var activeSessions = sessions

    switch providerFilter {
      case .all: break
      case .claude: activeSessions = activeSessions.filter { $0.provider == .claude }
      case .codex: activeSessions = activeSessions.filter { $0.provider == .codex }
    }

    if let projectFilter {
      activeSessions = activeSessions.filter { $0.projectPath == projectFilter }
    }

    let filtered: [RootSessionNode] = switch filter {
      case .all: activeSessions
      case .direct: activeSessions.filter(\.isDirect)
      case .attention: activeSessions.filter(\.displayStatus.needsAttention)
      case .running: activeSessions.filter { $0.displayStatus == .working }
      case .ready: activeSessions.filter { $0.displayStatus == .reply }
    }

    let attentionSessions = filtered.filter(\.displayStatus.needsAttention)
      .sorted { lhs, rhs in
        sortDate(lhs) < sortDate(rhs)
      }

    let workingSessions = filtered.filter { $0.displayStatus == .working }
      .sorted { lhs, rhs in sortSessions(lhs: lhs, rhs: rhs, sort: sort) }

    let readySessions = filtered.filter {
      let status = $0.displayStatus
      return !status.needsAttention && status != .working
    }
    .sorted { lhs, rhs in sortSessions(lhs: lhs, rhs: rhs, sort: sort) }

    return ActivityStream(
      attention: attentionSessions,
      working: workingSessions,
      ready: readySessions,
      ended: []
    )
  }

  private static func sortSessions(lhs: RootSessionNode, rhs: RootSessionNode, sort: ActiveSessionSort) -> Bool {
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
        let lhsPriority = statusPriority(lhs.displayStatus)
        let rhsPriority = statusPriority(rhs.displayStatus)
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

  private static func sortDate(_ session: RootSessionNode) -> Date {
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
