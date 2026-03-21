//
//  DashboardTriageCounts.swift
//  OrbitDock
//
//  Shared urgency counters for active dashboard sessions.
//

struct DashboardTriageCounts {
  var attention = 0
  var running = 0
  var ready = 0

  init(sessions: [RootSessionNode]) {
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

  init(conversations: [DashboardConversationRecord]) {
    for conversation in conversations {
      switch conversation.displayStatus {
        case .permission, .question: attention += 1
        case .working: running += 1
        case .reply: ready += 1
        case .ended: break
      }
    }
  }
}
