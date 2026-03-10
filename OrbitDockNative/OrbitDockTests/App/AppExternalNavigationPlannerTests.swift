import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct AppExternalNavigationPlannerTests {
  @Test func prefersUnifiedSessionsStoreLookupForScopedIDs() {
    let endpointId = UUID()
    let otherEndpointId = UUID()
    let session = Session(
      id: "session-1",
      projectPath: "/tmp/orbitdock",
      projectName: "OrbitDock",
      branch: nil,
      model: nil,
      contextLabel: nil,
      transcriptPath: nil,
      status: .active,
      workStatus: .unknown,
      startedAt: nil,
      endedAt: nil,
      endReason: nil,
      totalTokens: 0,
      totalCostUSD: 0,
      lastActivityAt: nil,
      lastTool: nil,
      lastToolAt: nil,
      promptCount: 0,
      toolCount: 0,
      terminalSessionId: nil,
      terminalApp: nil
    )

    let store = UnifiedSessionsStore()
    store.refresh(
      from: [
        UnifiedSessionsProjection.EndpointInput(
          endpoint: ServerEndpoint(
            id: endpointId,
            name: "Local",
            wsURL: URL(string: "ws://localhost:4000/ws")!,
            isLocalManaged: true,
            isEnabled: true,
            isDefault: true,
            authToken: nil
          ),
          status: .connected,
          sessions: [session]
        ),
      ]
    )

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: SessionRef(endpointId: endpointId, sessionId: "session-1").scopedID,
      explicitEndpointId: otherEndpointId,
      selectedEndpointId: otherEndpointId,
      fallbackEndpointId: otherEndpointId,
      unifiedSessionsStore: store
    )

    #expect(ref == SessionRef(endpointId: endpointId, sessionId: "session-1"))
  }

  @Test func fallsBackToExplicitEndpointWhenLookupMisses() {
    let explicitEndpointId = UUID()
    let store = UnifiedSessionsStore()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-2",
      explicitEndpointId: explicitEndpointId,
      selectedEndpointId: UUID(),
      fallbackEndpointId: UUID(),
      unifiedSessionsStore: store
    )

    #expect(ref == SessionRef(endpointId: explicitEndpointId, sessionId: "session-2"))
  }

  @Test func fallsBackToSelectedEndpointBeforeWindowFallback() {
    let selectedEndpointId = UUID()
    let fallbackEndpointId = UUID()
    let store = UnifiedSessionsStore()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-3",
      explicitEndpointId: nil,
      selectedEndpointId: selectedEndpointId,
      fallbackEndpointId: fallbackEndpointId,
      unifiedSessionsStore: store
    )

    #expect(ref == SessionRef(endpointId: selectedEndpointId, sessionId: "session-3"))
  }

  @Test func returnsNilWhenNoResolutionPathExists() {
    let store = UnifiedSessionsStore()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-4",
      explicitEndpointId: nil,
      selectedEndpointId: nil,
      fallbackEndpointId: nil,
      unifiedSessionsStore: store
    )

    #expect(ref == nil)
  }
}
