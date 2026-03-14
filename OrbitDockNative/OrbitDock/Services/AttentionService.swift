import Foundation

enum AttentionEventType {
  case permissionRequired
  case questionWaiting
  case unreviewedDiff
}

struct AttentionEvent: Identifiable {
  let id: String
  let sessionId: String
  let type: AttentionEventType
  let timestamp: Date
}

@Observable
@MainActor
final class AttentionService {
  private var eventsBySessionId: [String: [AttentionEvent]] = [:]

  private(set) var events: [AttentionEvent] = []

  var totalCount: Int {
    events.count
  }

  func events(for sessionId: String) -> [AttentionEvent] {
    eventsBySessionId[sessionId] ?? []
  }

  func update(sessions: [RootSessionNode]) {
    var newEventsBySessionId: [String: [AttentionEvent]] = [:]
    for session in sessions {
      newEventsBySessionId[session.scopedID] = attentionEvents(for: session)
    }
    eventsBySessionId = newEventsBySessionId
    rebuildFlatEvents()
  }

  func apply(session: RootSessionNode) {
    eventsBySessionId[session.scopedID] = attentionEvents(for: session)
    rebuildFlatEvents()
  }

  func remove(sessionId: String) {
    eventsBySessionId.removeValue(forKey: sessionId)
    rebuildFlatEvents()
  }

  private func attentionEvents(for session: RootSessionNode) -> [AttentionEvent] {
    guard session.showsInMissionControl else { return [] }

    let now = Date()
    var sessionEvents: [AttentionEvent] = []

    if session.displayStatus == .permission {
      sessionEvents.append(AttentionEvent(
        id: "attention-perm-\(session.scopedID)",
        sessionId: session.scopedID,
        type: .permissionRequired,
        timestamp: now
      ))
    }

    if session.displayStatus == .question {
      sessionEvents.append(AttentionEvent(
        id: "attention-question-\(session.scopedID)",
        sessionId: session.scopedID,
        type: .questionWaiting,
        timestamp: now
      ))
    }

    if session.hasTurnDiff {
      sessionEvents.append(AttentionEvent(
        id: "attention-diff-\(session.scopedID)",
        sessionId: session.scopedID,
        type: .unreviewedDiff,
        timestamp: now
      ))
    }

    return sessionEvents
  }

  private func rebuildFlatEvents() {
    events = eventsBySessionId.values
      .flatMap { $0 }
      .sorted { lhs, rhs in
        if lhs.timestamp != rhs.timestamp {
          return lhs.timestamp > rhs.timestamp
        }
        return lhs.id < rhs.id
      }
  }
}
