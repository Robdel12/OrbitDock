//
//  ExpandedToolModels.swift
//  OrbitDock
//
//  Shared model types for expanded tool cards.
//

import SwiftUI

enum NativeTodoStatus: Hashable {
  case pending
  case inProgress
  case completed
  case blocked
  case canceled
  case unknown

  init(_ rawStatus: String?) {
    let normalized = rawStatus?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "_")

    switch normalized {
      case "pending", "queued", "todo", "open": self = .pending
      case "in_progress", "inprogress", "active", "running": self = .inProgress
      case "completed", "complete", "done", "resolved": self = .completed
      case "blocked": self = .blocked
      case "canceled", "cancelled": self = .canceled
      default: self = .unknown
    }
  }

  var label: String {
    switch self {
      case .pending: "Pending"
      case .inProgress: "In Progress"
      case .completed: "Completed"
      case .blocked: "Blocked"
      case .canceled: "Canceled"
      case .unknown: "Unknown"
    }
  }
}

struct NativeTodoItem: Hashable {
  let content: String
  let activeForm: String?
  let status: NativeTodoStatus

  var primaryText: String {
    if status == .inProgress,
       let activeForm,
       !activeForm.isEmpty
    {
      return activeForm
    }
    return content
  }

  var secondaryText: String? {
    guard status == .inProgress,
          let activeForm,
          !activeForm.isEmpty,
          activeForm != content
    else {
      return nil
    }
    return content
  }
}

enum NativeToolContent {
  case bash(command: String, input: String?, output: String?)
  case edit(filename: String?, path: String?, additions: Int, deletions: Int, lines: [DiffLine], isWriteNew: Bool)
  case read(filename: String?, path: String?, language: String, lines: [String])
  case glob(pattern: String, grouped: [(dir: String, files: [String])])
  case grep(pattern: String, grouped: [(file: String, matches: [String])])
  case task(agentLabel: String, agentColor: PlatformColor, description: String, output: String?, isComplete: Bool)
  case todo(title: String, subtitle: String?, items: [NativeTodoItem], output: String?)
  case mcp(server: String, displayTool: String, subtitle: String?, input: String?, output: String?)
  case webFetch(domain: String, url: String, input: String?, output: String?)
  case webSearch(query: String, input: String?, output: String?)
  case generic(toolName: String, input: String?, output: String?)
}

struct NativeExpandedToolModel {
  let messageID: String
  let toolColor: PlatformColor
  let iconName: String
  let hasError: Bool
  let isInProgress: Bool
  let canCancel: Bool
  let duration: String?
  let linkedWorkerID: String?
  let content: NativeToolContent
}
