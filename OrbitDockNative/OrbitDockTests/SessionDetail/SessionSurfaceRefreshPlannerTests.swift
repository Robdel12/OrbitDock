import Foundation
@testable import OrbitDock
import Testing

struct SessionSurfaceRefreshPlannerTests {
  @Test func shouldRequestRefreshAllowsUnknownInvalidationRevision() {
    #expect(
      SessionSurfaceRefreshPlanner.shouldRequestRefresh(
        snapshotRevision: 10,
        pendingRevision: 11,
        incomingInvalidationRevision: nil
      )
    )
  }

  @Test func shouldRequestRefreshRejectsAlreadyAppliedRevision() {
    #expect(
      !SessionSurfaceRefreshPlanner.shouldRequestRefresh(
        snapshotRevision: 10,
        pendingRevision: nil,
        incomingInvalidationRevision: 10
      )
    )
    #expect(
      !SessionSurfaceRefreshPlanner.shouldRequestRefresh(
        snapshotRevision: 10,
        pendingRevision: nil,
        incomingInvalidationRevision: 9
      )
    )
  }

  @Test func shouldRequestRefreshRejectsAlreadyPendingRevision() {
    #expect(
      !SessionSurfaceRefreshPlanner.shouldRequestRefresh(
        snapshotRevision: nil,
        pendingRevision: 12,
        incomingInvalidationRevision: 12
      )
    )
    #expect(
      !SessionSurfaceRefreshPlanner.shouldRequestRefresh(
        snapshotRevision: 10,
        pendingRevision: 12,
        incomingInvalidationRevision: 11
      )
    )
  }

  @Test func shouldRequestRefreshAllowsNewerRevision() {
    #expect(
      SessionSurfaceRefreshPlanner.shouldRequestRefresh(
        snapshotRevision: 10,
        pendingRevision: 11,
        incomingInvalidationRevision: 12
      )
    )
  }

  @Test func nextPendingRevisionKeepsGreatestRevision() {
    #expect(
      SessionSurfaceRefreshPlanner.nextPendingRevision(
        pendingRevision: nil,
        incomingInvalidationRevision: nil
      ) == nil
    )
    #expect(
      SessionSurfaceRefreshPlanner.nextPendingRevision(
        pendingRevision: nil,
        incomingInvalidationRevision: 8
      ) == 8
    )
    #expect(
      SessionSurfaceRefreshPlanner.nextPendingRevision(
        pendingRevision: 8,
        incomingInvalidationRevision: 6
      ) == 8
    )
    #expect(
      SessionSurfaceRefreshPlanner.nextPendingRevision(
        pendingRevision: 8,
        incomingInvalidationRevision: 12
      ) == 12
    )
  }
}
