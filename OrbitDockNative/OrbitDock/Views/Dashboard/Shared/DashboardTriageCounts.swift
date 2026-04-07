//
//  DashboardTriageCounts.swift
//  OrbitDock
//
//  Shared urgency counters for active dashboard sessions.
//

struct DashboardTriageCounts: Sendable {
  var attention = 0
  var running = 0
  var ready = 0

  nonisolated init(attention: Int = 0, running: Int = 0, ready: Int = 0) {
    self.attention = attention
    self.running = running
    self.ready = ready
  }

  nonisolated init(sessions: [RootSessionNode]) {
    self.init()
    for session in sessions {
      guard session.showsInMissionControl else { continue }
      switch session.displayStatus {
        case .permission, .question: attention += 1
        case .working: running += 1
        case .reply: ready += 1
        case .ended: break
      }
    }
  }

  nonisolated init(conversations: [DashboardConversationRecord]) {
    self.init()
    for conversation in conversations {
      switch conversation.displayStatus {
        case .permission, .question: attention += 1
        case .working: running += 1
        case .reply: ready += 1
        case .ended: break
      }
    }
  }

  nonisolated static func + (lhs: Self, rhs: Self) -> Self {
    DashboardTriageCounts(
      attention: lhs.attention + rhs.attention,
      running: lhs.running + rhs.running,
      ready: lhs.ready + rhs.ready
    )
  }
}
