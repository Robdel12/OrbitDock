//
//  ToolFamily.swift
//  OrbitDock
//
//  Canonical tool family classification shared across both platforms.
//

import Foundation

nonisolated enum ToolFamily: String, Hashable, Sendable, CaseIterable {
  case shell
  case file
  case search
  case agent
  case question
  case plan
  case mcp
  case hook
  case web
  case skill
  case generic

  /// Classify a tool name into its semantic family.
  /// Falls back to `.generic` for unknown tools.
  static func classify(toolName: String?, isShell: Bool) -> ToolFamily {
    if isShell { return .shell }
    guard let rawName = toolName else { return .generic }

    let lowered = rawName.lowercased()

    // MCP-prefixed tools
    if lowered.hasPrefix("mcp__") {
      // Check if suffix maps to a known non-mcp family (e.g. mcp__todo_write)
      if let suffix = lowered.split(separator: "__").last {
        let suffixStr = String(suffix)
        switch suffixStr {
          case "todowrite", "todo_write", "taskcreate", "task_create",
               "taskupdate", "task_update", "tasklist", "task_list",
               "taskget", "task_get":
            return .plan
          default:
            break
        }
      }
      return .mcp
    }

    // Colon-separated names — use the suffix
    let normalized: String = if lowered.contains(":"), let suffix = lowered.split(separator: ":").last {
      String(suffix)
    } else {
      lowered
    }

    switch normalized {
      case "bash", "shell":
        return .shell
      case "read", "edit", "write", "notebookedit", "notebook_edit", "view_image":
        return .file
      case "glob", "grep", "toolsearch", "tool_search", "compactcontext":
        return .search
      case "task", "agent", "spawn_agent", "send_input", "wait", "handoff",
           "resume_agent", "close_agent":
        return .agent
      case "askuserquestion", "question":
        return .question
      case "enterplanmode", "exitplanmode", "plan", "update_plan",
           "todowrite", "todo_write", "taskcreate", "task_create",
           "taskupdate", "task_update", "tasklist", "task_list",
           "taskget", "task_get":
        return .plan
      case "hook":
        return .hook
      case "webfetch", "websearch":
        return .web
      case "skill":
        return .skill
      case "mcp_approval":
        return .mcp
      default:
        return .generic
    }
  }

  /// Initialize from a server-provided `tool_family` string.
  init(serverValue: String?) {
    guard let value = serverValue else {
      self = .generic
      return
    }
    self = ToolFamily(rawValue: value) ?? .generic
  }

}
