import SwiftUI

enum DashboardTab: String, CaseIterable {
  case missionControl
  case library
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
  var route: AppRoute = .dashboard(.missionControl)
  var showQuickSwitcher = false
  var showNewSessionSheet = false
  var newSessionProvider: SessionProvider = .claude
  var newSessionContinuation: SessionContinuation?
  var dashboardScrollAnchorID: String?

  /// Navigate to a session by scopedID (for toast taps, etc.)
  func navigateToSession(scopedID: String, source: NavigationSource = .external) {
    guard let ref = SessionRef(scopedID: scopedID) else { return }
    selectSession(ref, source: source)
  }

  func selectSession(_ ref: SessionRef, source: NavigationSource = .unspecified) {
    guard selectedSessionRef != ref else {
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
    route = .session(ref)
  }

  func goToDashboard(source: NavigationSource = .unspecified) {
    guard route != .dashboard(.missionControl) else {
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
    route = .dashboard(.missionControl)
  }

  func goToLibrary() {
    selectDashboardTab(.library)
  }

  func selectDashboardTab(_ tab: DashboardTab, source: NavigationSource = .unspecified) {
    guard route != .dashboard(tab) else {
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
    route = .dashboard(tab)
  }

  func openQuickSwitcher() {
    showQuickSwitcher = true
  }

  func closeQuickSwitcher() {
    showQuickSwitcher = false
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

  var selectedEndpointId: UUID? {
    selectedSessionRef?.endpointId
  }

  var dashboardTab: DashboardTab {
    get {
      guard case let .dashboard(tab) = route else { return .missionControl }
      return tab
    }
    set {
      selectDashboardTab(newValue)
    }
  }

  private var routeSummary: String {
    switch route {
      case let .dashboard(tab):
        "dashboard(\(tab.rawValue))"
      case let .session(ref):
        "session(\(ref.scopedID))"
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
