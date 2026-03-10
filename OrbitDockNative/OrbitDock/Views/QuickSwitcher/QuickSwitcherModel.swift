import Foundation

struct QuickSwitcherState {
  var searchText = ""
  var selectedIndex = 0
  var hoveredIndex: Int?
  var renamingSession: Session?
  var renameText = ""
  var targetSessionScopedID: String?
  var isRecentExpanded = false
  var quickLaunchMode: QuickLaunchProvider?
  var recentProjects: [ServerRecentProject] = []
  var isLoadingProjects = false
  var recentProjectsRequestId = UUID()

  mutating func resetSelection() {
    selectedIndex = 0
  }

  mutating func applySearchTransition(_ transition: QuickSwitcherSearchTransition) {
    targetSessionScopedID = transition.targetSession?.scopedID
    selectedIndex = transition.selectedIndex
    hoveredIndex = transition.hoveredIndex
    switch transition.mode {
      case .standard:
        quickLaunchMode = nil
      case .quickLaunch(let intent):
        quickLaunchMode = QuickLaunchProvider(intent: intent)
    }
  }

  mutating func beginRecentProjectsLoad(requestId: UUID) {
    isLoadingProjects = true
    recentProjectsRequestId = requestId
  }

  mutating func finishRecentProjectsLoad(
    requestId: UUID,
    endpointId: UUID?,
    activeEndpointId: UUID?,
    projects: [ServerRecentProject]
  ) {
    guard shouldApplyRecentProjectsResponse(
      requestId: requestId,
      requestEndpointId: endpointId,
      activeEndpointId: activeEndpointId
    ) else { return }
    recentProjects = projects
    isLoadingProjects = false
  }

  mutating func resetRecentProjects() {
    recentProjects = []
    isLoadingProjects = false
  }

  func shouldApplyRecentProjectsResponse(
    requestId: UUID,
    requestEndpointId: UUID?,
    activeEndpointId: UUID?
  ) -> Bool {
    recentProjectsRequestId == requestId && requestEndpointId == activeEndpointId
  }
}
