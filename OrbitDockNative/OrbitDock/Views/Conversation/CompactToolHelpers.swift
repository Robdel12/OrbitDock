//
//  CompactToolHelpers.swift
//  OrbitDock
//
//  Minimal utility helpers for tool display names, type mapping,
//  and output sanitization. All rich tool display computation is
//  done server-side via ToolDisplay.
//

import Foundation

enum CompactToolHelpers {
  private static let ansiRegex: NSRegularExpression? = try? NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[a-zA-Z]")

  // MARK: - Tool Type Mapping

  static func toolTypeFromString(_ value: String) -> CompactToolType {
    switch value {
      case "bash": return .bash
      case "read": return .read
      case "edit": return .edit
      case "glob": return .glob
      case "grep": return .grep
      case "task": return .task
      case "todo": return .todo
      case "mcp": return .mcp
      case "web": return .web
      case "plan": return .plan
      case "question": return .question
      case "skill": return .skill
      case "handoff": return .handoff
      case "hook": return .hook
      case "toolSearch": return .toolSearch
      default: return .generic
    }
  }

  // MARK: - Display Name

  static func displayName(for toolName: String) -> String {
    let normalized = normalizedToolName(toolName)
    switch normalized {
      case "bash": return "Bash"
      case "read": return "Read"
      case "edit": return "Edit"
      case "write": return "Write"
      case "glob": return "Glob"
      case "grep": return "Grep"
      case "task", "agent", "spawn_agent", "send_input", "wait", "resume_agent", "close_agent":
        return "Agent"
      case "handoff": return "Handoff"
      case "hook": return "Hook"
      case "webfetch": return "Fetch"
      case "websearch": return "Search"
      case "toolsearch", "tool_search": return "ToolSearch"
      case "skill": return "Skill"
      case "enterplanmode", "exitplanmode", "plan", "update_plan": return "Plan"
      case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget":
        return "Todo"
      case "askuserquestion", "question": return "Question"
      case "mcp_approval": return "MCP Approval"
      case "notebookedit": return "Notebook"
      default:
        if toolName.hasPrefix("mcp__") {
          return toolName
            .replacingOccurrences(of: "mcp__", with: "")
            .components(separatedBy: "__").last ?? "MCP"
        }
        return toolName
    }
  }

  // MARK: - MCP Server Name

  static func mcpServerName(for message: TranscriptMessage) -> String? {
    guard let name = message.toolName, name.hasPrefix("mcp__") else { return nil }
    let stripped = name.replacingOccurrences(of: "mcp__", with: "")
    return stripped.components(separatedBy: "__").first
  }

  // MARK: - Text Utilities

  static func compactSingleLineSummary(_ value: String, maxLength: Int = 180) -> String {
    let normalizedLines = value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")

    let collapsed = normalizedLines
      .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !collapsed.isEmpty else { return "tool" }
    guard collapsed.count > maxLength else { return collapsed }
    let truncated = String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    return truncated + "..."
  }

  // MARK: - Output Sanitization

  static func compactSanitizedOutputPrefix(for message: TranscriptMessage, maxChars: Int) -> String? {
    compactSanitizedExcerpt(message.toolOutput, maxChars: maxChars, fromEnd: false)
  }

  static func compactSanitizedOutputSuffix(for message: TranscriptMessage, maxChars: Int) -> String? {
    compactSanitizedExcerpt(message.toolOutput, maxChars: maxChars, fromEnd: true)
  }

  // MARK: - Private

  private static func normalizedToolName(_ toolName: String) -> String {
    let lowered = toolName.lowercased()
    if lowered.hasPrefix("mcp__"), let suffix = lowered.split(separator: "__").last {
      return String(suffix)
    }
    if lowered.contains(":") {
      let suffix = lowered.split(separator: ":").last ?? Substring(lowered)
      return String(suffix)
    }
    return lowered
  }

  private static func compactSanitizedExcerpt(_ raw: String?, maxChars: Int, fromEnd: Bool) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let excerpt: String
    if raw.count <= maxChars {
      excerpt = raw
    } else if fromEnd {
      excerpt = String(raw.suffix(maxChars))
    } else {
      excerpt = String(raw.prefix(maxChars))
    }

    guard let ansiRegex else {
      return excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : excerpt
    }

    let range = NSRange(excerpt.startIndex..., in: excerpt)
    let sanitized = ansiRegex.stringByReplacingMatches(in: excerpt, range: range, withTemplate: "")
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
