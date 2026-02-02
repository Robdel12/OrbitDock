//
//  Quest.swift
//  OrbitDock
//

import Foundation

struct Quest: Identifiable, Hashable {
  let id: String
  var name: String
  var description: String?
  var status: Status
  var color: String?
  let createdAt: Date
  var updatedAt: Date
  var completedAt: Date?

  // Relationships (populated separately)
  var links: [QuestLink]?
  var sessions: [Session]?
  var inboxItems: [InboxItem]?
  var notes: [QuestNote]?

  enum Status: String, CaseIterable {
    case active
    case paused
    case completed

    var label: String {
      switch self {
      case .active: "Active"
      case .paused: "Paused"
      case .completed: "Completed"
      }
    }

    var icon: String {
      switch self {
      case .active: "bolt.fill"
      case .paused: "pause.fill"
      case .completed: "checkmark.circle.fill"
      }
    }
  }

  var isActive: Bool { status == .active }
  var isPaused: Bool { status == .paused }
  var isCompleted: Bool { status == .completed }

  var sessionCount: Int { sessions?.count ?? 0 }
  var linkCount: Int { links?.count ?? 0 }
  var inboxCount: Int { inboxItems?.count ?? 0 }
  var noteCount: Int { notes?.count ?? 0 }

  // Hashable conformance (ignore relationships)
  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (lhs: Quest, rhs: Quest) -> Bool {
    lhs.id == rhs.id
  }
}

// MARK: - Quest Note

struct QuestNote: Identifiable, Hashable {
  let id: String
  let questId: String
  var title: String?
  var content: String
  let createdAt: Date
  var updatedAt: Date

  var displayTitle: String {
    if let title, !title.isEmpty {
      return title
    }
    // Use first line of content as title
    let firstLine = content.components(separatedBy: .newlines).first ?? content
    return String(firstLine.prefix(50))
  }

  var preview: String {
    String(content.prefix(100))
  }
}
