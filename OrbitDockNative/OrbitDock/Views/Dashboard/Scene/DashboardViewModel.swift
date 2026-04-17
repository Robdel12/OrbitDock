import Foundation
import Observation

@MainActor
@Observable
final class DashboardViewModel {
  // MARK: - Data source

  let dataService: DashboardDataService

  // MARK: - Local UI state

  var workbenchFilter: ActiveSessionWorkbenchFilter = .all
  var sort: ActiveSessionSort = .recent
  var providerFilter: ActiveSessionProviderFilter = .all
  var projectFilter: String?

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
    }
  }

  // MARK: - Init

  init(dataService: DashboardDataService) {
    self.dataService = dataService
  }

  // MARK: - Snapshot (reads from service — @Observable propagates automatically)

  var snapshot: DashboardSnapshot? {
    dataService.snapshot
  }

  // MARK: - Presentation (computed — rebuilds automatically when snapshot or filters change)

  var presentation: DashboardPresentation? {
    guard let snapshot else { return nil }
    return DashboardPresentationBuilder.build(
      snapshot: snapshot,
      filter: workbenchFilter,
      sort: sort,
      providerFilter: providerFilter,
      projectFilter: projectFilter,
      projectOrder: projectOrder
    )
  }

  // MARK: - Accessors for sub-views

  var dashboardConversations: [DashboardConversationRecord] {
    snapshot?.conversations ?? []
  }

  var dashboardHasMultipleEndpoints: Bool {
    snapshot?.hasMultipleEndpoints ?? false
  }

  var dashboardCounts: DashboardTriageCounts {
    snapshot?.counts ?? DashboardTriageCounts()
  }

  var dashboardDirectCount: Int {
    snapshot?.directCount ?? 0
  }

  var isLoading: Bool {
    snapshot == nil
  }

  // MARK: - Demo mode

  func refreshNow() async {
    await dataService.refreshNow()
  }

  func applySnapshot(_ newSnapshot: DashboardSnapshot) {
    dataService.applyDemoSnapshot(newSnapshot)
  }
}
