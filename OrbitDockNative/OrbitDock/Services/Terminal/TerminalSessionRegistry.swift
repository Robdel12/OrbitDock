import Foundation
import Observation

/// Manages all active terminal sessions for the application.
@Observable
final class TerminalSessionRegistry {
  private(set) var sessions: [String: TerminalSessionController] = [:]
  var activeTerminalId: String?

  var activeSession: TerminalSessionController? {
    guard let id = activeTerminalId else { return nil }
    return sessions[id]
  }

  var sortedSessions: [TerminalSessionController] {
    sessions.values.sorted { $0.id < $1.id }
  }

  func register(_ session: TerminalSessionController) {
    sessions[session.id] = session
    if activeTerminalId == nil {
      activeTerminalId = session.id
    }
  }

  func remove(_ terminalId: String) {
    sessions.removeValue(forKey: terminalId)
    if activeTerminalId == terminalId {
      activeTerminalId = sessions.keys.first
    }
  }

  func session(for terminalId: String) -> TerminalSessionController? {
    sessions[terminalId]
  }
}
