//
//  ToolCardStyle.swift
//  OrbitDock
//
//  Shared styling and helpers for tool cards
//

import SwiftUI

// MARK: - Tool Card Colors

enum ToolCardStyle {
  static func color(for toolName: String?) -> Color {
    guard let tool = toolName else { return .secondary }
    let lowercased = tool.lowercased()

    // Check for MCP tools first
    if tool.hasPrefix("mcp__") {
      let parts = tool.dropFirst(5).split(separator: "__", maxSplits: 1)
      if let server = parts.first {
        return MCPCard.serverColor(String(server))
      }
    }

    switch lowercased {
      case "read":
        return .toolRead
      case "edit", "write", "notebookedit":
        return .toolWrite
      case "bash":
        return .toolBash
      case "glob", "grep":
        return .toolSearch
      case "task":
        return .toolTask
      case "webfetch", "websearch":
        return .toolWeb
      case "askuserquestion":
        return .toolQuestion
      case "toolsearch":
        return .toolMcp
      case "skill":
        return .toolSkill
      case "enterplanmode", "exitplanmode":
        return .toolPlan
      case "taskcreate", "taskupdate", "tasklist", "taskget":
        return .toolTodo
      default:
        return .secondary
    }
  }

  static func icon(for toolName: String?) -> String {
    guard let tool = toolName else { return "gearshape" }
    let lowercased = tool.lowercased()

    // Check for MCP tools first
    if tool.hasPrefix("mcp__") {
      let parts = tool.dropFirst(5).split(separator: "__", maxSplits: 1)
      if let server = parts.first {
        return MCPCard.serverIcon(String(server))
      }
    }

    switch lowercased {
      case "read": return "doc.text.fill"
      case "edit": return "pencil"
      case "write": return "square.and.pencil"
      case "bash": return "terminal"
      case "glob": return "folder.badge.gearshape"
      case "grep": return "magnifyingglass"
      case "task": return "person.2.fill"
      case "webfetch": return "globe"
      case "websearch": return "magnifyingglass.circle"
      case "askuserquestion": return "questionmark.circle.fill"
      case "toolsearch": return "puzzlepiece.extension"
      case "skill": return "sparkles"
      case "enterplanmode": return "doc.text.magnifyingglass"
      case "exitplanmode": return "checkmark.rectangle"
      case "taskcreate": return "plus.circle.fill"
      case "taskupdate": return "pencil.circle.fill"
      case "tasklist": return "list.bullet.clipboard.fill"
      case "taskget": return "doc.text.fill"
      default: return "gearshape"
    }
  }

  /// Detect language from file extension
  static func detectLanguage(from path: String?) -> String {
    guard let path else { return "" }
    let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""

    switch ext {
      case "swift": return "swift"
      case "ts", "tsx": return "typescript"
      case "js", "jsx": return "javascript"
      case "py": return "python"
      case "rb": return "ruby"
      case "go": return "go"
      case "rs": return "rust"
      case "java": return "java"
      case "kt": return "kotlin"
      case "css", "scss": return "css"
      case "html": return "html"
      case "json": return "json"
      case "yaml", "yml": return "yaml"
      case "md": return "markdown"
      case "sh", "bash", "zsh": return "bash"
      case "sql": return "sql"
      default: return ""
    }
  }

  /// Shorten path for display
  static func shortenPath(_ path: String) -> String {
    let components = path.components(separatedBy: "/")
    if components.count > 3 {
      return ".../" + components.suffix(2).joined(separator: "/")
    }
    return path
  }
}
