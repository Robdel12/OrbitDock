import Foundation

@MainActor
@Observable
final class DashboardViewModel {
  var selectedIndex = 0
  var dashboardScrollAnchorID: String?
  var activeWorkbenchFilter: ActiveSessionWorkbenchFilter = .all
  var activeSort: ActiveSessionSort = .recent
  var activeProviderFilter: ActiveSessionProviderFilter = .all
  var activeProjectFilter: String?

  @ObservationIgnored private weak var appStore: AppStore?

  func bind(appStore: AppStore) {
    self.appStore = appStore
  }

  var rootSessions: [RootSessionNode] {
    appStore?.records() ?? []
  }

  var librarySessions: [RootSessionNode] {
    rootSessions
  }

  var dashboardConversations: [DashboardConversationRecord] {
    appStore?.dashboardConversationRecords() ?? []
  }

  var filteredDashboardConversations: [DashboardConversationRecord] {
    DashboardConversationDeckPlanner.build(
      from: dashboardConversations,
      filter: activeWorkbenchFilter,
      sort: activeSort,
      providerFilter: activeProviderFilter,
      projectFilter: activeProjectFilter
    )
  }

  var dashboardCounts: DashboardTriageCounts {
    DashboardTriageCounts(conversations: dashboardConversations)
  }

  var dashboardDirectCount: Int {
    dashboardConversations.filter(\.isDirect).count
  }

  var dashboardRefreshIdentity: String {
    appStore?.runtimeRegistry.dashboardRefreshIdentity ?? "dashboard-unbound"
  }

  func showingLoadingSkeleton(isInitialLoading: Bool) -> Bool {
    isInitialLoading && librarySessions.isEmpty
  }

  func refreshDashboardData() async {
    guard let appStore else { return }
    await appStore.runtimeRegistry.refreshDashboardConversations()
  }

  func syncSelectionBounds() {
    let count = filteredDashboardConversations.count
    guard count > 0 else {
      selectedIndex = 0
      return
    }

    if selectedIndex >= count {
      selectedIndex = count - 1
    }
  }

  func moveSelection(by delta: Int) {
    let conversations = filteredDashboardConversations
    guard !conversations.isEmpty else { return }

    let newIndex = selectedIndex + delta
    if newIndex < 0 {
      selectedIndex = conversations.count - 1
    } else if newIndex >= conversations.count {
      selectedIndex = 0
    } else {
      selectedIndex = newIndex
    }
  }

  func moveSelectionToFirst() {
    selectedIndex = 0
  }

  func moveSelectionToLast() {
    let conversations = filteredDashboardConversations
    guard !conversations.isEmpty else { return }
    selectedIndex = conversations.count - 1
  }

  var selectedConversation: DashboardConversationRecord? {
    let conversations = filteredDashboardConversations
    guard selectedIndex >= 0, selectedIndex < conversations.count else { return nil }
    return conversations[selectedIndex]
  }

  var selectedConversationScrollTargetID: String? {
    guard let selectedConversation else { return nil }
    return DashboardScrollIDs.session(selectedConversation.id)
  }
}

enum DashboardConversationDeckPlanner {
  static func build(
    from conversations: [DashboardConversationRecord],
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort,
    providerFilter: ActiveSessionProviderFilter,
    projectFilter: String?
  ) -> [DashboardConversationRecord] {
    var filtered = conversations

    switch providerFilter {
      case .all:
        break
      case .claude:
        filtered = filtered.filter { $0.provider == .claude }
      case .codex:
        filtered = filtered.filter { $0.provider == .codex }
    }

    if let projectFilter {
      filtered = filtered.filter { $0.groupingPath == projectFilter }
    }

    filtered = switch filter {
      case .all:
        filtered
      case .direct:
        filtered.filter(\.isDirect)
      case .attention:
        filtered.filter(\.displayStatus.needsAttention)
      case .running:
        filtered.filter { $0.displayStatus == .working }
      case .ready:
        filtered.filter { $0.displayStatus == .reply }
    }

    return filtered.sorted { lhs, rhs in
      sortConversations(lhs: lhs, rhs: rhs, sort: sort)
    }
  }

  private static func sortConversations(
    lhs: DashboardConversationRecord,
    rhs: DashboardConversationRecord,
    sort: ActiveSessionSort
  ) -> Bool {
    switch sort {
      case .recent, .tokens, .cost:
        return sortDate(lhs) > sortDate(rhs)
      case .name:
        let nameOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if nameOrder != .orderedSame {
          return nameOrder == .orderedAscending
        }
        return sortDate(lhs) > sortDate(rhs)
      case .status:
        let lhsPriority = statusPriority(lhs.displayStatus)
        let rhsPriority = statusPriority(rhs.displayStatus)
        if lhsPriority != rhsPriority {
          return lhsPriority < rhsPriority
        }
        return sortDate(lhs) > sortDate(rhs)
    }
  }

  private static func sortDate(_ conversation: DashboardConversationRecord) -> Date {
    conversation.lastActivityAt ?? conversation.startedAt ?? .distantPast
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
