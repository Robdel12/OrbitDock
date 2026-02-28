import SwiftUI

@Observable
final class AppRouter {
  var selectedSessionRef: SessionRef?
  var showQuickSwitcher = false
  var showNewClaudeSheet = false
  var showNewCodexSheet = false

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
  }

  func openQuickSwitcher() {
    showQuickSwitcher = true
  }

  func closeQuickSwitcher() {
    showQuickSwitcher = false
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
