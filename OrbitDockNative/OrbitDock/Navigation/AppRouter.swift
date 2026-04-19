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

enum WorkspaceSelection: Hashable {
  case overview
  case session(SessionRef)
  case mission(MissionRef)
  case missions
  case library
  case terminal(terminalId: String)
  case settings
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
  case settings
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
  let sourceServerInstanceId: String?
  let sourceIsRemoteConnection: Bool

  var sourceSummary: String {
    [provider.displayName, projectName, model]
      .compactMap { $0 }
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: " · ")
  }

  func isSupported(
    on endpointId: UUID,
    isRemoteConnection: Bool,
    selectedServerInstanceId: String?
  ) -> Bool {
    guard !sourceIsRemoteConnection, !isRemoteConnection else { return false }

    let sourceId = sourceServerInstanceId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectedId = selectedServerInstanceId?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let sourceId, !sourceId.isEmpty, let selectedId, !selectedId.isEmpty {
      return sourceId == selectedId
    }

    return false
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
  /// The single source of truth for what the workspace displays.
  var workspaceSelection: WorkspaceSelection = .overview {
    didSet {
      guard oldValue != workspaceSelection else { return }
      previousSelection = oldValue
    }
  }

  /// One level of navigation history for context-aware back navigation.
  private(set) var previousSelection: WorkspaceSelection?
  var selectedMissionTabs: [MissionRef: MissionTab] = [:]

  var isSidebarCollapsed = false

  var showQuickSwitcher = false
  var showNewSessionSheet = false
  var newSessionProvider: SessionProvider = .claude
  var newSessionContinuation: SessionContinuation?
  var route: AppRoute {
    switch workspaceSelection {
      case .overview: .dashboard(.missionControl)
      case let .session(ref): .session(ref)
      case let .mission(ref): .mission(ref)
      case .missions: .dashboard(.missions)
      case .library: .dashboard(.library)
      case let .terminal(terminalId): .terminal(terminalId: terminalId)
      case .settings: .settings
    }
  }

  /// Derived from `workspaceSelection` for views that read `dashboardTab`.
  var dashboardTab: DashboardTab {
    switch workspaceSelection {
      case .missions: .missions
      case .library: .library
      default: .missionControl
    }
  }

  /// Navigate to a session by scopedID (for toast taps, etc.)
  func navigateToSession(scopedID: String, source: NavigationSource = .external) {
    guard let ref = SessionRef(scopedID: scopedID) else { return }
    selectSession(ref, source: source)
  }

  func navigateToMission(
    missionId: String,
    endpointId: UUID,
    source _: NavigationSource = .unspecified
  ) {
    let ref = MissionRef(endpointId: endpointId, missionId: missionId)
    if selectedMissionTabs[ref] == nil {
      selectedMissionTabs[ref] = .overview
    }
    workspaceSelection = .mission(ref)
  }

  func selectSession(_ ref: SessionRef, source _: NavigationSource = .unspecified) {
    guard workspaceSelection != .session(ref) else { return }
    workspaceSelection = .session(ref)
  }

  /// Navigate back to the previous selection, falling back to overview.
  func goBack(source _: NavigationSource = .unspecified) {
    updateSelectionWithoutAnimation(previousSelection ?? .overview)
  }

  /// Human-readable label for the back button.
  var backDestinationLabel: String {
    guard let prev = previousSelection else { return "Overview" }
    switch prev {
      case .overview: return "Overview"
      case .session: return "Session"
      case .mission: return "Mission"
      case .missions: return "Missions"
      case .library: return "Library"
      case .terminal: return "Terminal"
      case .settings: return "Settings"
    }
  }

  func toggleSidebar() {
    #if os(macOS)
      NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    #else
      withAnimation(Motion.standard) {
        isSidebarCollapsed.toggle()
      }
    #endif
  }

  func goToDashboard(source _: NavigationSource = .unspecified) {
    guard workspaceSelection != .overview else { return }
    updateSelectionWithoutAnimation(.overview)
  }

  func goToLibrary() {
    selectDashboardTab(.library)
  }

  func goToSettings(source _: NavigationSource = .unspecified) {
    guard workspaceSelection != .settings else { return }
    workspaceSelection = .settings
  }

  func selectDashboardTab(_ tab: DashboardTab, source _: NavigationSource = .unspecified) {
    let targetSelection: WorkspaceSelection = switch tab {
      case .missionControl: .overview
      case .missions: .missions
      case .library: .library
    }

    guard workspaceSelection != targetSelection else { return }
    workspaceSelection = targetSelection
  }

  func openQuickSwitcher() {
    showQuickSwitcher = true
  }

  func closeQuickSwitcher() {
    showQuickSwitcher = false
  }

  func navigateToTerminal(terminalId: String, source _: NavigationSource = .unspecified) {
    workspaceSelection = .terminal(terminalId: terminalId)
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
    guard case let .session(ref) = workspaceSelection else { return nil }
    return ref
  }

  var selectedMissionRef: MissionRef? {
    guard case let .mission(ref) = workspaceSelection else { return nil }
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

  private func updateSelectionWithoutAnimation(_ selection: WorkspaceSelection) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      workspaceSelection = selection
    }
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
