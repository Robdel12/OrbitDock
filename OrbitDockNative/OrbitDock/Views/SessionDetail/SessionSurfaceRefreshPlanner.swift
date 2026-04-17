import Foundation

enum SessionSurfaceRefreshPlanner {
  static func shouldRequestRefresh(
    snapshotRevision: UInt64?,
    pendingRevision: UInt64?,
    incomingInvalidationRevision: UInt64?
  ) -> Bool {
    guard let incomingInvalidationRevision else { return true }

    if let snapshotRevision, incomingInvalidationRevision <= snapshotRevision {
      return false
    }

    if let pendingRevision, incomingInvalidationRevision <= pendingRevision {
      return false
    }

    return true
  }

  static func nextPendingRevision(
    pendingRevision: UInt64?,
    incomingInvalidationRevision: UInt64?
  ) -> UInt64? {
    guard let incomingInvalidationRevision else { return pendingRevision }
    return max(pendingRevision ?? incomingInvalidationRevision, incomingInvalidationRevision)
  }
}
