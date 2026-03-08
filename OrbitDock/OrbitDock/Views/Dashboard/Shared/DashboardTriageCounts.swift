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

  init(sessions: [Session]) {
    for session in sessions {
      guard session.showsInMissionControl else { continue }
      let status = SessionDisplayStatus.from(session)
      switch status {
        case .permission, .question: attention += 1
        case .working: running += 1
        case .reply: ready += 1
        case .ended: break
      }
    }
  }
}
