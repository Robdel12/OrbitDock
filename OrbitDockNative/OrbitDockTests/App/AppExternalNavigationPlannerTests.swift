import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct AppExternalNavigationPlannerTests {
  @Test func prefersStoreLookupForScopedIDs() {
    let endpointId = UUID()
    let otherEndpointId = UUID()
    let store = makeTestAppStore()

    let item = makeSessionListItem(id: "session-1")
    store.seed(records: [
      RootSessionNode(
        session: item,
        endpointId: endpointId,
        endpointName: "Local",
        connectionStatus: .connected
      ),
    ])

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: SessionRef(endpointId: endpointId, sessionId: "session-1").scopedID,
      explicitEndpointId: otherEndpointId,
      selectedEndpointId: otherEndpointId,
      fallbackEndpointId: otherEndpointId,
      store: store
    )

    #expect(ref == SessionRef(endpointId: endpointId, sessionId: "session-1"))
  }

  @Test func fallsBackToExplicitEndpointWhenLookupMisses() {
    let explicitEndpointId = UUID()
    let store = makeTestAppStore()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-2",
      explicitEndpointId: explicitEndpointId,
      selectedEndpointId: UUID(),
      fallbackEndpointId: UUID(),
      store: store
    )

    #expect(ref == SessionRef(endpointId: explicitEndpointId, sessionId: "session-2"))
  }

  @Test func fallsBackToSelectedEndpointBeforeWindowFallback() {
    let selectedEndpointId = UUID()
    let fallbackEndpointId = UUID()
    let store = makeTestAppStore()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-3",
      explicitEndpointId: nil,
      selectedEndpointId: selectedEndpointId,
      fallbackEndpointId: fallbackEndpointId,
      store: store
    )

    #expect(ref == SessionRef(endpointId: selectedEndpointId, sessionId: "session-3"))
  }

  @Test func returnsNilWhenNoResolutionPathExists() {
    let store = makeTestAppStore()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-4",
      explicitEndpointId: nil,
      selectedEndpointId: nil,
      fallbackEndpointId: nil,
      store: store
    )

    #expect(ref == nil)
  }
}

@MainActor
private func makeTestAppStore() -> AppStore {
  let registry = ServerRuntimeRegistry(
    endpointsProvider: { [] },
    runtimeFactory: { _ in fatalError("No runtime in test") },
    shouldBootstrapFromSettings: false
  )
  return AppStore(runtimeRegistry: registry)
}

private func makeSessionListItem(id: String) -> ServerSessionListItem {
  ServerSessionListItem(
    id: id,
    provider: .codex,
    projectPath: "/tmp/\(id)",
    projectName: "OrbitDock",
    gitBranch: "main",
    model: "gpt-5.4",
    status: .active,
    workStatus: .reply,
    codexIntegrationMode: .passive,
    claudeIntegrationMode: nil,
    startedAt: "2026-03-11T10:00:00Z",
    lastActivityAt: "2026-03-11T10:05:00Z",
    unreadCount: 0,
    hasTurnDiff: false,
    pendingToolName: nil,
    repositoryRoot: "/tmp",
    isWorktree: false,
    worktreeId: nil,
    totalTokens: 0,
    totalCostUSD: 0.0,
    displayTitle: "OrbitDock",
    displayTitleSortKey: "orbitdock",
    displaySearchText: "orbitdock main",
    contextLine: nil,
    listStatus: nil,
    effort: nil
  )
}
