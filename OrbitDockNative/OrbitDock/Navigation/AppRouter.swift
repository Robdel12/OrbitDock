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
    [
      provider.displayName,
      projectName,
      normalizedModelLabel,
    ]
    .compactMap { value in
      guard let value else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
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

  private var normalizedModelLabel: String? {
    guard let model else { return nil }
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

@MainActor
@Observable
final class AppRouter {
  var route: AppRoute = .dashboard(.missionControl)
  private var lastSelectedEndpointId: UUID?
  var dashboardScrollAnchorID: String?
  var showQuickSwitcher = false
  var showNewSessionSheet = false
  var newSessionProvider: SessionProvider = .claude
  var newSessionContinuation: SessionContinuation?

  func selectSession(_ ref: SessionRef) {
    let message = "selectSession scopedID=\(ref.scopedID)"
    print("[OrbitDock][Router] \(message)")
    NSLog("[OrbitDock][Router] %@", message)
    route = .session(ref)
    lastSelectedEndpointId = ref.endpointId
  }

  func selectSession(scopedID: String, store: AppStore) {
    guard let ref = store.sessionRef(for: scopedID) else {
      return
    }
    selectSession(ref)
  }

  /// Navigate to a session by scopedID. Resolves via SessionRef parsing.
  func navigateToSession(scopedID: String) {
    let message = "navigateToSession scopedID=\(scopedID)"
    print("[OrbitDock][Router] \(message)")
    NSLog("[OrbitDock][Router] %@", message)
    guard let ref = SessionRef(scopedID: scopedID) else { return }
    selectSession(ref)
  }

  func goToDashboard() {
    print("[OrbitDock][Router] goToDashboard")
    NSLog("[OrbitDock][Router] goToDashboard")
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

  /// For NotificationCenter, push notifications, menu bar — external navigation sources
  func handleExternalNavigation(
    sessionID: String,
    endpointId: UUID?,
    store: AppStore,
    fallbackEndpointId: UUID?
  ) {
    if let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: sessionID,
      explicitEndpointId: endpointId,
      selectedEndpointId: selectedEndpointId,
      fallbackEndpointId: fallbackEndpointId,
      store: store
    ) {
      selectSession(ref)
    }
  }

  var selectedSessionRef: SessionRef? {
    guard case let .session(ref) = route else { return nil }
    return ref
  }

  var selectedEndpointId: UUID? {
    selectedSessionRef?.endpointId ?? lastSelectedEndpointId
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
