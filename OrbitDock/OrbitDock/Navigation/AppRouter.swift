import SwiftUI

enum DashboardTab: String, CaseIterable {
  case missionControl
  case library
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
  var selectedSessionRef: SessionRef?
  var dashboardTab: DashboardTab = .missionControl
  var dashboardScrollAnchorID: String?
  var showQuickSwitcher = false
  var showNewSessionSheet = false
  var newSessionProvider: SessionProvider = .claude
  var newSessionContinuation: SessionContinuation?

  func selectSession(_ ref: SessionRef, runtimeRegistry: ServerRuntimeRegistry) {
    runtimeRegistry.setActiveEndpoint(id: ref.endpointId)
    selectedSessionRef = ref
  }

  func selectSession(scopedID: String, store: UnifiedSessionsStore, runtimeRegistry: ServerRuntimeRegistry) {
    guard let ref = store.sessionRef(for: scopedID) else {
      selectedSessionRef = nil
      return
    }
    selectSession(ref, runtimeRegistry: runtimeRegistry)
  }

  /// Navigate to a session by scopedID. Resolves via SessionRef parsing.
  func navigateToSession(scopedID: String, runtimeRegistry: ServerRuntimeRegistry) {
    guard let ref = SessionRef(scopedID: scopedID) else { return }
    selectSession(ref, runtimeRegistry: runtimeRegistry)
  }

  func goToDashboard() {
    selectedSessionRef = nil
    dashboardTab = .missionControl
  }

  func goToLibrary() {
    selectedSessionRef = nil
    dashboardTab = .library
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
    store: UnifiedSessionsStore,
    runtimeRegistry: ServerRuntimeRegistry
  ) {
    // Strategy 1: Look up by scopedID in the unified store
    if let ref = store.sessionRef(for: sessionID) {
      selectSession(ref, runtimeRegistry: runtimeRegistry)
      return
    }

    // Strategy 2: Build ref from explicit endpointId
    if let endpointId {
      let ref = SessionRef(endpointId: endpointId, sessionId: sessionID)
      selectSession(ref, runtimeRegistry: runtimeRegistry)
      return
    }

    // Strategy 3: Fall back to active endpoint
    if let activeEndpointId = runtimeRegistry.activeEndpointId {
      let ref = SessionRef(endpointId: activeEndpointId, sessionId: sessionID)
      selectSession(ref, runtimeRegistry: runtimeRegistry)
    }
  }

  var selectedScopedID: String? {
    selectedSessionRef?.scopedID
  }
}
