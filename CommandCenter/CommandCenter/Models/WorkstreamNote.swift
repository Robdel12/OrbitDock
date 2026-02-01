//
//  WorkstreamNote.swift
//  OrbitDock
//
//  A note, decision, blocker, or pivot logged during a workstream
//  These are the "story" of how a feature came to be
//

import Foundation

struct WorkstreamNote: Identifiable, Equatable {
  let id: String
  let workstreamId: String
  var sessionId: String?

  let type: NoteType
  let content: String
  var metadata: [String: Any]?

  let createdAt: Date
  var resolvedAt: Date?

  enum NoteType: String, CaseIterable {
    case note
    case decision
    case blocker
    case pivot
    case milestone

    var icon: String {
      switch self {
        case .note: "note.text"
        case .decision: "arrow.triangle.branch"
        case .blocker: "exclamationmark.octagon"
        case .pivot: "arrow.uturn.right"
        case .milestone: "flag.checkered"
      }
    }

    var label: String {
      switch self {
        case .note: "Note"
        case .decision: "Decision"
        case .blocker: "Blocker"
        case .pivot: "Pivot"
        case .milestone: "Milestone"
      }
    }

    var color: String {
      switch self {
        case .note: "textSecondary"
        case .decision: "accent"
        case .blocker: "statusError"
        case .pivot: "statusWaiting"
        case .milestone: "statusSuccess"
      }
    }
  }

  // MARK: - Computed Properties

  var isResolved: Bool {
    resolvedAt != nil
  }

  /// For Equatable - ignore metadata since it's [String: Any]
  static func == (lhs: WorkstreamNote, rhs: WorkstreamNote) -> Bool {
    lhs.id == rhs.id &&
      lhs.workstreamId == rhs.workstreamId &&
      lhs.sessionId == rhs.sessionId &&
      lhs.type == rhs.type &&
      lhs.content == rhs.content &&
      lhs.createdAt == rhs.createdAt &&
      lhs.resolvedAt == rhs.resolvedAt
  }
}
