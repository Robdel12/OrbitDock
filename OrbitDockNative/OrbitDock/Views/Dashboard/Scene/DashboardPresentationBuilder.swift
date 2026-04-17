import Foundation

enum DashboardPresentationBuilder {
  static func build(
    snapshot: DashboardSnapshot,
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort,
    providerFilter: ActiveSessionProviderFilter,
    projectFilter: String?,
    projectOrder: [String]
  ) -> DashboardPresentation {
    let filtered = filterAndSort(
      snapshot.conversations,
      filter: filter,
      sort: sort,
      providerFilter: providerFilter,
      projectFilter: projectFilter
    )

    let sidebar = filterAndSort(
      snapshot.conversations,
      filter: filter,
      sort: sort,
      providerFilter: providerFilter,
      projectFilter: nil
    )

    let groups = buildGroups(from: filtered, customOrder: projectOrder)
    let sidebarGroups = buildGroups(from: sidebar, customOrder: projectOrder)

    return DashboardPresentation(
      groups: groups,
      sidebarGroups: sidebarGroups,
      filteredConversations: filtered,
      sidebarConversations: sidebar
    )
  }

  // MARK: - Filtering & Sorting

  private static func filterAndSort(
    _ conversations: [DashboardConversationRecord],
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort,
    providerFilter: ActiveSessionProviderFilter,
    projectFilter: String?
  ) -> [DashboardConversationRecord] {
    var result = conversations

    switch providerFilter {
      case .all:
        break
      case .claude:
        result = result.filter { $0.provider == .claude }
      case .codex:
        result = result.filter { $0.provider == .codex }
    }

    if let projectFilter {
      result = result.filter { $0.groupingPath == projectFilter }
    }

    result = switch filter {
      case .all:
        result
      case .direct:
        result.filter(\.isDirect)
      case .attention:
        result.filter(\.displayStatus.needsAttention)
      case .running:
        result.filter { $0.displayStatus == .working }
      case .ready:
        result.filter { $0.displayStatus == .reply }
    }

    return sortConversations(result, sort: sort)
  }

  private static func sortConversations(
    _ conversations: [DashboardConversationRecord],
    sort: ActiveSessionSort
  ) -> [DashboardConversationRecord] {
    if preservesServerOrdering(sort: sort) {
      return conversations
    }

    return conversations.sorted { lhs, rhs in
      switch sort {
        case .name:
          let nameOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
          if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
          }
          let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
          let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
          return lhsDate > rhsDate
        case .status:
          let lhsPriority = lhs.displayStatus.sortPriority
          let rhsPriority = rhs.displayStatus.sortPriority
          if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
          }
          let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
          let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
          return lhsDate > rhsDate
        case .recent, .tokens, .cost:
          return false
      }
    }
  }

  private static func preservesServerOrdering(sort: ActiveSessionSort) -> Bool {
    switch sort {
      case .recent, .status, .tokens, .cost:
        true
      case .name:
        false
    }
  }

  // MARK: - Grouping

  private static func buildGroups(
    from conversations: [DashboardConversationRecord],
    customOrder: [String]
  ) -> [ConversationProjectGroup] {
    ConversationProjectGroupBuilder.build(from: conversations, customOrder: customOrder)
  }
}
