import Foundation
import Observation

@MainActor
@Observable
final class DashboardViewModel {
  var selectedIndex = 0
  var dashboardScrollAnchorID: String?
  var activeWorkbenchFilter: ActiveSessionWorkbenchFilter = .all {
    didSet { recomputeDerivedCollections() }
  }

  var activeSort: ActiveSessionSort = .recent {
    didSet { recomputeDerivedCollections() }
  }

  var activeProviderFilter: ActiveSessionProviderFilter = .all {
    didSet { recomputeDerivedCollections() }
  }

  var activeProjectFilter: String? {
    didSet { recomputeDerivedCollections() }
  }

  var rootSessions: [RootSessionNode] = []
  var filteredDashboardConversations: [DashboardConversationRecord] = []
  var sidebarConversations: [DashboardConversationRecord] = []
  var missionControlGroups: [ConversationProjectGroup] = []
  var sidebarGroups: [ConversationProjectGroup] = []

  /// Custom project ordering — persisted to UserDefaults.
  /// Empty array means "use alphabetical order."
  var projectOrder: [String] = {
    guard let data = UserDefaults.standard.data(forKey: "dashboard.projectOrder"),
          let paths = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return paths
  }() {
    didSet {
      if let data = try? JSONEncoder().encode(projectOrder) {
        UserDefaults.standard.set(data, forKey: "dashboard.projectOrder")
      }
      recomputeDerivedCollections()
    }
  }

  @ObservationIgnored private weak var dashboardProjectionStore: DashboardProjectionStore?
  @ObservationIgnored private var observationGeneration: UInt64 = 0

  func bind(projectionStore: DashboardProjectionStore) {
    dashboardProjectionStore = projectionStore
    observationGeneration &+= 1
    startObservation(generation: observationGeneration)
  }

  func showingLoadingSkeleton(isInitialLoading: Bool) -> Bool {
    isInitialLoading && librarySessions.isEmpty
  }

  func refreshDashboardData() async {
    guard let dashboardProjectionStore else { return }
    await dashboardProjectionStore.refreshDashboardData()
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

  private func startObservation(generation: UInt64) {
    guard let projectionStore = dashboardProjectionStore else {
      applyBaseState(.empty)
      return
    }

    withObservationTracking {
      applyBaseState(
        DashboardProjectionSnapshot(
          rootSessions: projectionStore.rootSessions,
          dashboardConversations: projectionStore.dashboardConversations,
          hasMultipleEndpoints: projectionStore.hasMultipleEndpoints,
          counts: projectionStore.counts,
          directCount: projectionStore.directCount,
          refreshIdentity: projectionStore.refreshIdentity
        )
      )
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.observationGeneration == generation else { return }
        self.startObservation(generation: generation)
      }
    }
  }

  private func applyBaseState(_ snapshot: DashboardProjectionSnapshot) {
    rootSessions = snapshot.rootSessions
    filteredDashboardConversations = snapshot.dashboardConversations
    recomputeDerivedCollections()
  }

  private func recomputeDerivedCollections() {
    guard let dashboardProjectionStore else {
      filteredDashboardConversations = []
      sidebarConversations = []
      missionControlGroups = []
      sidebarGroups = []
      syncSelectionBounds()
      return
    }

    let dashboardConversations = dashboardProjectionStore.dashboardConversations
    filteredDashboardConversations = DashboardConversationDeckPlanner.build(
      from: dashboardConversations,
      filter: activeWorkbenchFilter,
      sort: activeSort,
      providerFilter: activeProviderFilter,
      projectFilter: activeProjectFilter
    )
    sidebarConversations = DashboardConversationDeckPlanner.build(
      from: dashboardConversations,
      filter: activeWorkbenchFilter,
      sort: activeSort,
      providerFilter: activeProviderFilter,
      projectFilter: nil
    )
    missionControlGroups = ConversationProjectGroupBuilder.build(
      from: filteredDashboardConversations,
      customOrder: projectOrder
    )
    sidebarGroups = ConversationProjectGroupBuilder.build(
      from: sidebarConversations,
      customOrder: projectOrder
    )
    syncSelectionBounds()
  }

  var librarySessions: [RootSessionNode] {
    rootSessions
  }

  var libraryHasMoreSessions: Bool {
    dashboardProjectionStore?.runtimeRegistry?.hasMoreLibrarySessions ?? false
  }

  func loadMoreLibrarySessions() async {
    guard let runtimeRegistry = dashboardProjectionStore?.runtimeRegistry else { return }
    await runtimeRegistry.loadMoreLibrarySessions()
  }

  var dashboardConversations: [DashboardConversationRecord] {
    dashboardProjectionStore?.dashboardConversations ?? []
  }

  var dashboardHasMultipleEndpoints: Bool {
    dashboardProjectionStore?.hasMultipleEndpoints ?? false
  }

  var dashboardCounts: DashboardTriageCounts {
    dashboardProjectionStore?.counts ?? DashboardTriageCounts(conversations: [])
  }

  var dashboardDirectCount: Int {
    dashboardProjectionStore?.directCount ?? 0
  }

  var dashboardRefreshIdentity: String {
    dashboardProjectionStore?.refreshIdentity ?? "dashboard-unbound"
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
