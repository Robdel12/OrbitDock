import SwiftUI

enum DashboardTab: String, CaseIterable {
  case missionControl
  case missions
  case library

  var navigationTitle: String {
    switch self {
      case .missionControl: "Active"
      case .missions: "Missions"
      case .library: "Library"
    }
  }
}

enum NavigationSource: String, Sendable {
  case unspecified
  case external
  case commandMenu
  case dashboardSidebar
  case dashboardStream
  case dashboardKeyboard
  case dashboardTabSwitcher
  case quickSwitcher
  case library
  case sessionHeader
}

enum AppRoute: Equatable {
  case dashboard(DashboardTab)
  case session(SessionRef)
  case mission(MissionRef)
  case terminal(terminalId: String)
}

/// The destinations that can be pushed onto the navigation stack.
/// `AppRoute.dashboard` is the root and never appears in the stack.
enum AppNavDestination: Hashable, Sendable {
  case session(SessionRef)
  case mission(MissionRef)
  case terminal(terminalId: String)
}

struct SessionContinuation: Hashable, Sendable {
  let endpointId: UUID
  let sessionId: String
  let provider: Provider
  let displayName: String
  let projectPath: String
  let model: String?
  let hasGitRepository: Bool

  var sourceSummary: String {
    [provider.displayName, projectName, model]
      .compactMap { $0 }
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: " · ")
  }

  func isSupported(on endpointId: UUID, isRemoteConnection: Bool) -> Bool {
    !isRemoteConnection && self.endpointId == endpointId
  }

  func bootstrapPrompt() -> String {
    var lines = [
      "Continue work from OrbitDock session \(sessionId).",
      "",
      "First, run:",
      "orbitdock -j session get \(sessionId) -m",
      "",
      "Read that session for context. Summarize the goal, current status, files touched, current branch, and the next best step. Then continue the work in this session.",
    ]
    if hasGitRepository {
      lines.append("")
      lines.append("Use the existing repo/worktree at \(projectPath).")
    }
    return lines.joined(separator: "\n")
  }

  private var projectName: String? {
    URL(fileURLWithPath: projectPath).lastPathComponent
  }
}

@MainActor
@Observable
final class AppRouter {
  /// The iOS NavigationStack path — the single source of truth for navigation.
  /// macOS ContentView derives its displayed view from `route` (computed below).
  var navigationStack: [AppNavDestination] = []
  var dashboardTab: DashboardTab = .missionControl
  var selectedMissionTabs: [MissionRef: MissionTab] = [:]

  var showQuickSwitcher = false
  var showNewSessionSheet = false
  var newSessionProvider: SessionProvider = .claude
  var newSessionContinuation: SessionContinuation?
  var dashboardScrollAnchorID: String?

  /// Computed from `navigationStack` and `dashboardTab`. All existing read
  /// sites continue to work unchanged; macOS ContentView switches on this.
  var route: AppRoute {
    switch navigationStack.last {
      case let .session(ref): .session(ref)
      case let .mission(ref): .mission(ref)
      case let .terminal(terminalId): .terminal(terminalId: terminalId)
      case nil: .dashboard(dashboardTab)
    }
  }

  /// Navigate to a session by scopedID (for toast taps, etc.)
  func navigateToSession(scopedID: String, source: NavigationSource = .external) {
    guard let ref = SessionRef(scopedID: scopedID) else { return }
    selectSession(ref, source: source)
  }

  func navigateToMission(missionId: String, endpointId: UUID, source: NavigationSource = .unspecified) {
    let ref = MissionRef(endpointId: endpointId, missionId: missionId)
    logNavigation(
      action: "navigateToMission",
      source: source,
      outcome: "applied",
      details: "missionId=\(missionId) from=\(routeSummary)"
    )
    if selectedMissionTabs[ref] == nil {
      selectedMissionTabs[ref] = .overview
    }
    navigationStack = [.mission(ref)]
  }

  func selectSession(_ ref: SessionRef, source: NavigationSource = .unspecified) {
    guard navigationStack.last != .session(ref) else {
      logNavigation(
        action: "selectSession",
        source: source,
        outcome: "noop",
        details: "scopedID=\(ref.scopedID) route=\(routeSummary)"
      )
      return
    }

    logNavigation(
      action: "selectSession",
      source: source,
      outcome: "applied",
      details: "scopedID=\(ref.scopedID) from=\(routeSummary)"
    )
    navigationStack = [.session(ref)]
  }

  func goToDashboard(source: NavigationSource = .unspecified) {
    guard !navigationStack.isEmpty || dashboardTab != .missionControl else {
      logNavigation(
        action: "goToDashboard",
        source: source,
        outcome: "noop",
        details: "route=\(routeSummary)"
      )
      return
    }

    logNavigation(
      action: "goToDashboard",
      source: source,
      outcome: "applied",
      details: "from=\(routeSummary)"
    )
    var t = Transaction(animation: nil)
    t.disablesAnimations = true
    withTransaction(t) {
      navigationStack = []
      dashboardTab = .missionControl
    }
  }

  func goToLibrary() {
    selectDashboardTab(.library)
  }

  func selectDashboardTab(_ tab: DashboardTab, source: NavigationSource = .unspecified) {
    guard !navigationStack.isEmpty || dashboardTab != tab else {
      logNavigation(
        action: "selectDashboardTab",
        source: source,
        outcome: "noop",
        details: "tab=\(tab.rawValue) route=\(routeSummary)"
      )
      return
    }

    logNavigation(
      action: "selectDashboardTab",
      source: source,
      outcome: "applied",
      details: "tab=\(tab.rawValue) from=\(routeSummary)"
    )
    navigationStack = []
    dashboardTab = tab
  }

  func openQuickSwitcher() {
    showQuickSwitcher = true
  }

  func closeQuickSwitcher() {
    showQuickSwitcher = false
  }

  func navigateToTerminal(terminalId: String, source: NavigationSource = .unspecified) {
    logNavigation(
      action: "navigateToTerminal",
      source: source,
      outcome: "applied",
      details: "terminalId=\(terminalId) from=\(routeSummary)"
    )
    navigationStack = [.terminal(terminalId: terminalId)]
  }

  func openNewSessionSheet() {
    newSessionContinuation = nil
    showNewSessionSheet = true
  }

  func openNewSession(provider: SessionProvider, continuation: SessionContinuation? = nil) {
    newSessionProvider = provider
    newSessionContinuation = continuation
    showNewSessionSheet = true
  }

  func closeNewSessionSheet() {
    showNewSessionSheet = false
    newSessionContinuation = nil
  }

  var selectedSessionRef: SessionRef? {
    guard case let .session(ref) = route else { return nil }
    return ref
  }

  var selectedMissionRef: MissionRef? {
    guard case let .mission(ref) = route else { return nil }
    return ref
  }

  func selectedMissionTab(for ref: MissionRef) -> MissionTab {
    selectedMissionTabs[ref] ?? .overview
  }

  func selectMissionTab(_ tab: MissionTab, for ref: MissionRef) {
    selectedMissionTabs[ref] = tab
  }

  var selectedEndpointId: UUID? {
    selectedSessionRef?.endpointId ?? selectedMissionRef?.endpointId
  }

  private var routeSummary: String {
    switch route {
      case let .dashboard(tab):
        "dashboard(\(tab.rawValue))"
      case let .session(ref):
        "session(\(ref.scopedID))"
      case let .mission(ref):
        "mission(\(ref.missionId))"
      case let .terminal(terminalId):
        "terminal(\(terminalId))"
    }
  }

  private func logNavigation(
    action: String,
    source: NavigationSource,
    outcome: String,
    details: String
  ) {
    print("[OrbitDock][Router] \(action) source=\(source.rawValue) outcome=\(outcome) \(details)")
  }
}

private struct OrbitDockRouterFocusedValueKey: FocusedValueKey {
  typealias Value = AppRouter
}

extension FocusedValues {
  var orbitDockRouter: AppRouter? {
    get { self[OrbitDockRouterFocusedValueKey.self] }
    set { self[OrbitDockRouterFocusedValueKey.self] = newValue }
  }
}
