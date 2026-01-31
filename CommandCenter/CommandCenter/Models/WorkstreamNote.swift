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
            case .note: return "note.text"
            case .decision: return "arrow.triangle.branch"
            case .blocker: return "exclamationmark.octagon"
            case .pivot: return "arrow.uturn.right"
            case .milestone: return "flag.checkered"
            }
        }

        var label: String {
            switch self {
            case .note: return "Note"
            case .decision: return "Decision"
            case .blocker: return "Blocker"
            case .pivot: return "Pivot"
            case .milestone: return "Milestone"
            }
        }

        var color: String {
            switch self {
            case .note: return "textSecondary"
            case .decision: return "accent"
            case .blocker: return "statusError"
            case .pivot: return "statusWaiting"
            case .milestone: return "statusSuccess"
            }
        }
    }

    // MARK: - Computed Properties

    var isResolved: Bool {
        resolvedAt != nil
    }

    // For Equatable - ignore metadata since it's [String: Any]
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
