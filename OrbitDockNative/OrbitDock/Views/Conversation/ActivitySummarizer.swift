//
//  ActivitySummarizer.swift
//  OrbitDock
//
//  Generates human-readable semantic summaries from groups of tool call messages.
//  "Explored 12 files across 3 directories ~3.1s" instead of "29 Bash, 2 Read, 1 Glob"
//

import Foundation
import SwiftUI

nonisolated struct ActivitySummary: Hashable, Sendable {
  let text: String
  let icon: String
  let colorKey: String
  let totalDuration: TimeInterval?
}

nonisolated enum ActivitySummarizer {

  // MARK: - Tool Categories

  private enum ToolCategory: Hashable {
    case search
    case edit
    case bash
    case task
    case web
    case todo
    case plan
    case other
  }

  /// Lightweight snapshot of tool call data extracted on MainActor, safe to pass across isolation.
  struct ToolSnapshot: Sendable {
    let toolName: String
    let isShell: Bool
    let filePath: String?
    let globOutputFiles: [String]
    let isNewFile: Bool // write with no old_string
    let hasBashError: Bool
    let duration: TimeInterval?
  }

  /// Call from MainActor to extract Sendable snapshots from TranscriptMessages.
  @MainActor static func extractSnapshots(from messages: [TranscriptMessage]) -> [ToolSnapshot] {
    messages.compactMap { msg -> ToolSnapshot? in
      guard msg.type == .tool || msg.type == .shell else { return nil }
      let name = msg.toolName?.lowercased() ?? (msg.type == .shell ? "bash" : "tool")
      let path = msg.filePath
      let globFiles: [String] = if name == "glob", let output = msg.toolOutput {
        output.components(separatedBy: "\n").filter { !$0.isEmpty }
      } else {
        []
      }
      let isNew = name == "write" && msg.editOldString == nil
      let hasError = msg.bashHasError
      return ToolSnapshot(
        toolName: name,
        isShell: msg.type == .shell,
        filePath: path,
        globOutputFiles: globFiles,
        isNewFile: isNew,
        hasBashError: hasError,
        duration: msg.toolDuration
      )
    }
  }

  /// Generate a semantic summary from pre-extracted snapshots (nonisolated-safe).
  nonisolated static func summarize(snapshots: [ToolSnapshot]) -> ActivitySummary {
    guard !snapshots.isEmpty else {
      return ActivitySummary(text: "No operations", icon: "circle", colorKey: "secondary", totalDuration: nil)
    }

    let categorized = snapshots.map { (snap: $0, category: categorize($0)) }
    let totalDuration = snapshots.compactMap(\.duration).reduce(0, +)
    let duration: TimeInterval? = totalDuration > 0 ? totalDuration : nil

    var categoryCounts: [ToolCategory: Int] = [:]
    for entry in categorized {
      categoryCounts[entry.category, default: 0] += 1
    }

    let total = snapshots.count
    let dominant = categoryCounts.max(by: { $0.value < $1.value })

    // Semantic data
    var allFiles = Set<String>()
    var editedFiles = Set<String>()
    var newFileCount = 0
    var bashErrorCount = 0

    for snap in snapshots {
      if let path = snap.filePath { allFiles.insert(path) }
      allFiles.formUnion(snap.globOutputFiles)
      if ["edit", "write", "notebookedit"].contains(snap.toolName), let path = snap.filePath {
        editedFiles.insert(path)
      }
      if snap.isNewFile { newFileCount += 1 }
      if snap.hasBashError { bashErrorCount += 1 }
    }

    let uniqueDirs = Set(allFiles.compactMap { path -> String? in
      let comps = path.components(separatedBy: "/")
      return comps.count > 1 ? comps.dropLast().joined(separator: "/") : nil
    })

    let searchCount = categoryCounts[.search] ?? 0
    let editCount = categoryCounts[.edit] ?? 0
    let bashCount = categoryCounts[.bash] ?? 0
    let taskCount = categoryCounts[.task] ?? 0

    let text: String
    let icon: String
    let colorKey: String

    switch dominant?.key {
    case .search where searchCount > total / 2:
      let fileCount = allFiles.count
      let dirCount = uniqueDirs.count
      if fileCount > 0, dirCount > 1 {
        text = "Explored \(fileCount) files across \(dirCount) directories"
      } else if fileCount > 0 {
        text = "Searched \(fileCount) files"
      } else {
        text = "Searched codebase (\(searchCount) queries)"
      }
      icon = "magnifyingglass"
      colorKey = "search"

    case .edit where editCount > total / 2:
      let editFileCount = editedFiles.count
      if newFileCount > 0, editFileCount > newFileCount {
        text = "Modified \(editFileCount - newFileCount) files, created \(newFileCount) new"
      } else if newFileCount > 0 {
        text = "Created \(newFileCount) new \(newFileCount == 1 ? "file" : "files")"
      } else if editFileCount > 0 {
        text = "Edited \(editFileCount) \(editFileCount == 1 ? "file" : "files")"
      } else {
        text = "Made \(editCount) \(editCount == 1 ? "edit" : "edits")"
      }
      icon = "pencil.line"
      colorKey = "write"

    case .bash where bashCount > total / 2:
      if bashErrorCount > 0 {
        text = "Ran \(bashCount) commands (\(bashErrorCount) with errors)"
      } else {
        text = "Ran \(bashCount) \(bashCount == 1 ? "command" : "commands")"
      }
      icon = "terminal"
      colorKey = "bash"

    case .task where taskCount > 0:
      text = "Launched \(taskCount) \(taskCount == 1 ? "agent" : "agents")"
      icon = "bolt.fill"
      colorKey = "task"

    default:
      let parts = categoryCounts
        .sorted { $0.value > $1.value }
        .prefix(3)
        .map { categoryLabel($0.key, count: $0.value) }
      text = parts.joined(separator: ", ")
      icon = dominant.map { categoryIcon($0.key) } ?? "gearshape"
      colorKey = dominant.map { categoryColorKey($0.key) } ?? "secondary"
    }

    return ActivitySummary(text: text, icon: icon, colorKey: colorKey, totalDuration: duration)
  }

  /// Convenience: summarize messages directly (calls extractSnapshots internally).
  /// Only call from @MainActor context since it accesses TranscriptMessage computed properties.
  @MainActor static func summarize(_ messages: [TranscriptMessage]) -> ActivitySummary {
    let snapshots = extractSnapshots(from: messages)
    return summarize(snapshots: snapshots)
  }

  // MARK: - Categorization

  nonisolated private static func categorize(_ snap: ToolSnapshot) -> ToolCategory {
    if snap.isShell { return .bash }
    switch snap.toolName {
    case "bash": return .bash
    case "read", "glob", "grep", "websearch": return .search
    case "edit", "write", "notebookedit": return .edit
    case "task": return .task
    case "webfetch": return .web
    case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan":
      return .todo
    case "enterplanmode", "exitplanmode": return .plan
    default: return .other
    }
  }

  // MARK: - Display Helpers

  nonisolated private static func categoryLabel(_ category: ToolCategory, count: Int) -> String {
    switch category {
    case .search: "\(count) search"
    case .edit: "\(count) \(count == 1 ? "edit" : "edits")"
    case .bash: "\(count) \(count == 1 ? "command" : "commands")"
    case .task: "\(count) \(count == 1 ? "agent" : "agents")"
    case .web: "\(count) \(count == 1 ? "fetch" : "fetches")"
    case .todo: "\(count) todo"
    case .plan: "plan mode"
    case .other: "\(count) \(count == 1 ? "operation" : "operations")"
    }
  }

  nonisolated private static func categoryIcon(_ category: ToolCategory) -> String {
    switch category {
    case .search: "magnifyingglass"
    case .edit: "pencil.line"
    case .bash: "terminal"
    case .task: "bolt.fill"
    case .web: "globe"
    case .todo: "checklist"
    case .plan: "map"
    case .other: "gearshape"
    }
  }

  nonisolated private static func categoryColorKey(_ category: ToolCategory) -> String {
    switch category {
    case .search: "search"
    case .edit: "write"
    case .bash: "bash"
    case .task: "task"
    case .web: "web"
    case .todo: "todo"
    case .plan: "plan"
    case .other: "secondary"
    }
  }
}

// MARK: - Duration Formatting

extension ActivitySummary {
  var formattedDuration: String? {
    guard let duration = totalDuration, duration > 0 else { return nil }
    if duration < 1.0 {
      return "\(Int(duration * 1000))ms"
    } else if duration < 60 {
      return String(format: "%.1fs", duration)
    } else {
      let minutes = Int(duration / 60)
      let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
      return "\(minutes)m \(seconds)s"
    }
  }
}
