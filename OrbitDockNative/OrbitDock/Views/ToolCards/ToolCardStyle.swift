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
    let normalized = lowercased.split(separator: ":").last.map(String.init) ?? lowercased
    if ["todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget"].contains(normalized) {
      return .toolTodo
    }

    // Check for MCP tools first
    if tool.hasPrefix("mcp__") {
      let parts = tool.dropFirst(5).split(separator: "__", maxSplits: 1)
      if let server = parts.first {
        return mcpServerColor(String(server))
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
      case "view_image":
        return .toolRead
      case "askuserquestion":
        return .toolQuestion
      case "toolsearch":
        return .toolMcp
      case "skill":
        return .toolSkill
      case "enterplanmode", "exitplanmode":
        return .toolPlan
      case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget":
        return .toolTodo
      default:
        return .secondary
    }
  }

  static func icon(for toolName: String?) -> String {
    guard let tool = toolName else { return "gearshape" }
    let lowercased = tool.lowercased()
    let normalized = lowercased.split(separator: ":").last.map(String.init) ?? lowercased
    if ["todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget"].contains(normalized) {
      return "checklist"
    }

    // Check for MCP tools first
    if tool.hasPrefix("mcp__") {
      let parts = tool.dropFirst(5).split(separator: "__", maxSplits: 1)
      if let server = parts.first {
        return mcpServerIcon(String(server))
      }
    }

    switch lowercased {
      case "read": return "doc.plaintext"
      case "edit": return "pencil.line"
      case "write": return "pencil.line"
      case "bash": return "terminal"
      case "glob": return "magnifyingglass"
      case "grep": return "magnifyingglass"
      case "task": return "bolt.fill"
      case "webfetch": return "globe"
      case "websearch": return "globe"
      case "view_image": return "photo"
      case "askuserquestion": return "questionmark.bubble"
      case "toolsearch": return "puzzlepiece.extension"
      case "skill": return "sparkles"
      case "enterplanmode", "exitplanmode", "updateplan": return "map"
      case "todowrite", "todo_write": return "checklist"
      case "taskcreate": return "plus.circle.fill"
      case "taskupdate": return "pencil.circle.fill"
      case "tasklist": return "list.bullet.clipboard.fill"
      case "taskget": return "doc.plaintext"
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

  /// Heuristic JSON detection — shared across all tool card views.
  static func looksLikeJSON(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
      || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
  }

  // MARK: - MCP Server Styling

  static func mcpServerColor(_ server: String) -> Color {
    switch server.lowercased() {
      case "github":
        .serverGitHub
      case "linear-server", "linear":
        .serverLinear
      case "chrome-devtools", "chrome":
        .serverChrome
      case "slack":
        .serverSlack
      case "cupertino":
        .serverApple
      default:
        .serverDefault
    }
  }

  static func mcpServerIcon(_ server: String) -> String {
    switch server.lowercased() {
      case "github":
        "chevron.left.forwardslash.chevron.right"
      case "linear-server", "linear":
        "list.bullet.rectangle"
      case "chrome-devtools", "chrome":
        "globe"
      case "slack":
        "bubble.left.and.bubble.right"
      case "cupertino":
        "apple.logo"
      default:
        "puzzlepiece.extension"
    }
  }
}
