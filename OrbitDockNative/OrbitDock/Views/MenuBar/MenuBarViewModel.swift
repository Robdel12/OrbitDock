import Foundation
import Observation

@MainActor
@Observable
final class MenuBarViewModel {
  var snapshot = MenuBarSnapshot.empty

  func applySessions(_ sessions: [RootSessionNode]) {
    snapshot = MenuBarSnapshot(
      activeSessions: RootSessionSnapshotLoader.missionControlSessions(from: sessions, limit: 8),
      recentSessions: RootSessionSnapshotLoader.recentSessions(from: sessions, limit: 5),
      totalCount: RootSessionSnapshotLoader.counts(from: sessions).total
    )
  }
}
