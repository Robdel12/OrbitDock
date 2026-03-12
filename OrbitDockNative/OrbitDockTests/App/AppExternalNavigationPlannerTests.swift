import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct AppExternalNavigationPlannerTests {
  @Test func prefersRootShellLookupForScopedIDs() {
    let endpointId = UUID()
    let otherEndpointId = UUID()
    let store = RootShellStore()

    store.apply(
      .sessionsList(
        endpointId: endpointId,
        endpointName: "Local",
        connectionStatus: .connected,
        sessions: [makeSessionListItem(id: "session-1")]
      )
    )

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: SessionRef(endpointId: endpointId, sessionId: "session-1").scopedID,
      explicitEndpointId: otherEndpointId,
      selectedEndpointId: otherEndpointId,
      fallbackEndpointId: otherEndpointId,
      rootShellStore: store
    )

    #expect(ref == SessionRef(endpointId: endpointId, sessionId: "session-1"))
  }

  @Test func fallsBackToExplicitEndpointWhenLookupMisses() {
    let explicitEndpointId = UUID()
    let store = RootShellStore()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-2",
      explicitEndpointId: explicitEndpointId,
      selectedEndpointId: UUID(),
      fallbackEndpointId: UUID(),
      rootShellStore: store
    )

    #expect(ref == SessionRef(endpointId: explicitEndpointId, sessionId: "session-2"))
  }

  @Test func fallsBackToSelectedEndpointBeforeWindowFallback() {
    let selectedEndpointId = UUID()
    let fallbackEndpointId = UUID()
    let store = RootShellStore()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-3",
      explicitEndpointId: nil,
      selectedEndpointId: selectedEndpointId,
      fallbackEndpointId: fallbackEndpointId,
      rootShellStore: store
    )

    #expect(ref == SessionRef(endpointId: selectedEndpointId, sessionId: "session-3"))
  }

  @Test func returnsNilWhenNoResolutionPathExists() {
    let store = RootShellStore()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-4",
      explicitEndpointId: nil,
      selectedEndpointId: nil,
      fallbackEndpointId: nil,
      rootShellStore: store
    )

    #expect(ref == nil)
  }
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
