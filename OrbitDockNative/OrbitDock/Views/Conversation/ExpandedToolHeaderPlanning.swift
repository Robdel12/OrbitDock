//
//  ExpandedToolHeaderPlanning.swift
//  OrbitDock
//
//  Shared header planning for expanded tool cards.
//

import Foundation

enum ExpandedToolHeaderTitlePlan: Equatable {
  case plain(text: String, style: ExpandedToolHeaderTitleStyle)
  case bash(command: String)
}

enum ExpandedToolHeaderTitleStyle: Equatable {
  case primary
  case toolTint
  case fileName
}

enum ExpandedToolHeaderStatsTone: Equatable {
  case secondary
  case diff(additions: Int, deletions: Int)
}

struct ExpandedToolHeaderPlan: Equatable {
  let title: ExpandedToolHeaderTitlePlan
  let subtitle: String?
  let statsText: String?
  let statsTone: ExpandedToolHeaderStatsTone
}

enum ExpandedToolHeaderPlanning {
  static func plan(for model: NativeExpandedToolModel) -> ExpandedToolHeaderPlan {
    switch model.content {
      case let .bash(command, _, _):
        return ExpandedToolHeaderPlan(
          title: .bash(command: command),
          subtitle: nil,
          statsText: nil,
          statsTone: .secondary
        )

      case let .edit(filename, path, additions, deletions, _, _):
        var parts: [String] = []
        if deletions > 0 { parts.append("−\(deletions)") }
        if additions > 0 { parts.append("+\(additions)") }
        return ExpandedToolHeaderPlan(
          title: .plain(text: filename ?? "Edit", style: .primary),
          subtitle: path.map { shortenPath($0) },
          statsText: parts.isEmpty ? nil : parts.joined(separator: " "),
          statsTone: .diff(additions: additions, deletions: deletions)
        )

      case let .read(filename, path, language, lines):
        let statsText = "\(lines.count) lines" + (language.isEmpty ? "" : " · \(language)")
        return ExpandedToolHeaderPlan(
          title: .plain(text: filename ?? "Read", style: .fileName),
          subtitle: path.map { shortenPath($0) },
          statsText: statsText,
          statsTone: .secondary
        )

      case let .glob(pattern, grouped):
        let fileCount = grouped.reduce(0) { $0 + $1.files.count }
        return ExpandedToolHeaderPlan(
          title: .plain(text: "Glob", style: .toolTint),
          subtitle: pattern,
          statsText: "\(fileCount) \(fileCount == 1 ? "file" : "files")",
          statsTone: .secondary
        )

      case let .grep(pattern, grouped):
        let matchCount = grouped.reduce(0) { $0 + max(1, $1.matches.count) }
        return ExpandedToolHeaderPlan(
          title: .plain(text: "Grep", style: .toolTint),
          subtitle: pattern,
          statsText: "\(matchCount) in \(grouped.count) \(grouped.count == 1 ? "file" : "files")",
          statsTone: .secondary
        )

      case let .task(agentLabel, _, description, _, isComplete):
        return ExpandedToolHeaderPlan(
          title: .plain(text: agentLabel, style: .toolTint),
          subtitle: description.isEmpty ? nil : description,
          statsText: isComplete ? "Complete" : "Running...",
          statsTone: .secondary
        )

      case let .todo(title, subtitle, items, _):
        let completedCount = items.filter { $0.status == .completed }.count
        let activeCount = items.filter { $0.status == .inProgress }.count
        let statsText: String?
        if !items.isEmpty {
          var parts = ["\(completedCount)/\(items.count) done"]
          if activeCount > 0 {
            parts.append("\(activeCount) active")
          }
          statsText = parts.joined(separator: " · ")
        } else if model.isInProgress {
          statsText = "Syncing..."
        } else {
          statsText = nil
        }
        return ExpandedToolHeaderPlan(
          title: .plain(text: title, style: .toolTint),
          subtitle: subtitle?.isEmpty == false ? subtitle : nil,
          statsText: statsText,
          statsTone: .secondary
        )

      case let .mcp(server, displayTool, subtitle, _, _):
        return ExpandedToolHeaderPlan(
          title: .plain(text: displayTool, style: .toolTint),
          subtitle: subtitle,
          statsText: server,
          statsTone: .secondary
        )

      case let .webFetch(domain, _, _, _):
        return ExpandedToolHeaderPlan(
          title: .plain(text: "WebFetch", style: .toolTint),
          subtitle: domain,
          statsText: nil,
          statsTone: .secondary
        )

      case let .webSearch(query, _, _):
        return ExpandedToolHeaderPlan(
          title: .plain(text: "WebSearch", style: .toolTint),
          subtitle: query,
          statsText: nil,
          statsTone: .secondary
        )

      case let .generic(toolName, _, _):
        return ExpandedToolHeaderPlan(
          title: .plain(text: toolName, style: .toolTint),
          subtitle: nil,
          statsText: nil,
          statsTone: .secondary
        )
    }
  }

  private static func shortenPath(_ path: String) -> String {
    let components = path.components(separatedBy: "/")
    if components.count > 4 {
      return components.suffix(3).joined(separator: "/")
    }
    return path
  }
}
