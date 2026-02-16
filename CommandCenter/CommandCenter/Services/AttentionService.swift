//
//  AttentionService.swift
//  OrbitDock
//
//  Tracks which sessions need user attention and why.
//  Standalone service — will be wired to the Attention Strip in Phase 1.
//

import Foundation

// MARK: - Attention Event

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

// MARK: - Attention Service

@Observable
@MainActor
final class AttentionService {
  private(set) var events: [AttentionEvent] = []

  var totalCount: Int {
    events.count
  }

  func events(for sessionId: String) -> [AttentionEvent] {
    events.filter { $0.sessionId == sessionId }
  }

  /// Recompute attention events from current session state.
  func update(sessions: [Session], sessionObservable: (String) -> SessionObservable) {
    var newEvents: [AttentionEvent] = []

    for session in sessions where session.status == .active {
      let obs = sessionObservable(session.id)
      let now = Date()

      // Permission required
      if session.workStatus == .permission || session.attentionReason == .awaitingPermission {
        newEvents.append(AttentionEvent(
          id: "attention-perm-\(session.id)",
          sessionId: session.id,
          type: .permissionRequired,
          timestamp: now
        ))
      }

      // Question waiting
      if session.attentionReason == .awaitingQuestion {
        newEvents.append(AttentionEvent(
          id: "attention-question-\(session.id)",
          sessionId: session.id,
          type: .questionWaiting,
          timestamp: now
        ))
      }

      // Unreviewed diff (has turn diffs that exist)
      if !obs.turnDiffs.isEmpty {
        newEvents.append(AttentionEvent(
          id: "attention-diff-\(session.id)",
          sessionId: session.id,
          type: .unreviewedDiff,
          timestamp: now
        ))
      }
    }

    events = newEvents
  }
}
