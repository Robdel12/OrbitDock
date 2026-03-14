import SwiftUI

enum DashboardTab: String, CaseIterable {
  case missionControl
  case library
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
  func navigateToSession(scopedID: String) {
    guard let ref = SessionRef(scopedID: scopedID) else { return }
    selectSession(ref)
  }

  func selectSession(_ ref: SessionRef) {
    print("[OrbitDock][Router] selectSession scopedID=\(ref.scopedID)")
    route = .session(ref)
  }

  func goToDashboard() {
    print("[OrbitDock][Router] goToDashboard")
    route = .dashboard(.missionControl)
  }

  func goToLibrary() {
    route = .dashboard(.library)
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
      route = .dashboard(newValue)
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
