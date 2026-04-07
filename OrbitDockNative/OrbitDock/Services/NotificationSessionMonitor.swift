import Foundation
import Observation

@MainActor
@Observable
final class NotificationSessionMonitor {
  var sessions: [RootSessionNode] = []

  func applySessions(_ sessions: [RootSessionNode]) {
    self.sessions = RootSessionSnapshotLoader.sortSessions(sessions)
  }
}
