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
  func update(sessions: [Session], sessionObservable: (Session) -> SessionObservable?) {
    var newEvents: [AttentionEvent] = []

    for session in sessions where session.showsInMissionControl {
      let obs = sessionObservable(session)
      let now = Date()

      // Permission required
      if session.workStatus == .permission || session.attentionReason == .awaitingPermission {
        newEvents.append(AttentionEvent(
          id: "attention-perm-\(session.scopedID)",
          sessionId: session.scopedID,
          type: .permissionRequired,
          timestamp: now
        ))
      }

      // Question waiting
      if session.attentionReason == .awaitingQuestion {
        newEvents.append(AttentionEvent(
          id: "attention-question-\(session.scopedID)",
          sessionId: session.scopedID,
          type: .questionWaiting,
          timestamp: now
        ))
      }

      // Unreviewed diff (has turn diffs that exist)
      if let obs, !obs.turnDiffs.isEmpty {
        newEvents.append(AttentionEvent(
          id: "attention-diff-\(session.scopedID)",
          sessionId: session.scopedID,
          type: .unreviewedDiff,
          timestamp: now
        ))
      }
    }

    events = newEvents
  }
}
