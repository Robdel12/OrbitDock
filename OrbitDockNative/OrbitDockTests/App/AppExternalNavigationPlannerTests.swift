import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct AppExternalNavigationPlannerTests {
  @Test func prefersExplicitEndpointId() {
    let explicitEndpointId = UUID()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-1",
      explicitEndpointId: explicitEndpointId,
      selectedEndpointId: UUID(),
      fallbackEndpointId: UUID()
    )

    #expect(ref == SessionRef(endpointId: explicitEndpointId, sessionId: "session-1"))
  }

  @Test func fallsBackToSelectedEndpointBeforeWindowFallback() {
    let selectedEndpointId = UUID()
    let fallbackEndpointId = UUID()

    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-3",
      explicitEndpointId: nil,
      selectedEndpointId: selectedEndpointId,
      fallbackEndpointId: fallbackEndpointId
    )

    #expect(ref == SessionRef(endpointId: selectedEndpointId, sessionId: "session-3"))
  }

  @Test func returnsNilWhenNoResolutionPathExists() {
    let ref = AppExternalNavigationPlanner.resolvedSessionRef(
      sessionID: "session-4",
      explicitEndpointId: nil,
      selectedEndpointId: nil,
      fallbackEndpointId: nil
    )

    #expect(ref == nil)
  }
}
