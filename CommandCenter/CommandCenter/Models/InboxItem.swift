//
//  InboxItem.swift
//  OrbitDock
//

import Foundation

struct InboxItem: Identifiable, Hashable {
  let id: String
  let content: String
  let source: Source
  var sessionId: String?
  var questId: String?
  var status: Status
  var linearIssueId: String?
  var linearIssueUrl: String?
  let createdAt: Date
  var attachedAt: Date?
  var completedAt: Date?

  enum Source: String {
    case manual
    case cli
    case quickswitcher

    var label: String {
      switch self {
        case .manual: "Manual"
        case .cli: "CLI"
        case .quickswitcher: "Quick Switcher"
      }
    }

    var icon: String {
      switch self {
        case .manual: "hand.tap"
        case .cli: "terminal"
        case .quickswitcher: "command"
      }
    }
  }

  enum Status: String {
    case pending // In inbox, needs processing
    case attached // Linked to a quest
    case converted // Turned into Linear issue
    case completed // Done/handled
    case archived // Saved for later / not now

    var label: String {
      switch self {
        case .pending: "Pending"
        case .attached: "Attached"
        case .converted: "Linear"
        case .completed: "Done"
        case .archived: "Archived"
      }
    }

    var icon: String {
      switch self {
        case .pending: "tray"
        case .attached: "scope"
        case .converted: "link"
        case .completed: "checkmark.circle.fill"
        case .archived: "archivebox"
      }
    }

    /// Whether this item is considered "processed" (out of active inbox)
    var isProcessed: Bool {
      switch self {
        case .pending: false
        case .attached, .converted, .completed, .archived: true
      }
    }
  }

  var isAttached: Bool {
    questId != nil
  }

  var isPending: Bool {
    status == .pending
  }

  /// Preview of content (truncated for display)
  var preview: String {
    if content.count <= 80 {
      return content
    }
    return String(content.prefix(77)) + "..."
  }
}
