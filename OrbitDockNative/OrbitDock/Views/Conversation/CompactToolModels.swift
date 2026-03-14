//
//  CompactToolModels.swift
//  OrbitDock
//
//  View model for compact tool rows. Mirrors the server's ToolDisplay 1:1
//  plus message-level fields (worker linkage, progress state). The cell is
//  a pure renderer — no tool-specific branching here.
//

import SwiftUI

// MARK: - Tool Type (dispatch only, no visual meaning)

nonisolated enum CompactToolType: Hashable, Sendable {
  case bash, read, edit, glob, grep, task, todo, mcp, web, plan, question, skill, handoff, hook, toolSearch, generic
}

// MARK: - Diff Preview (from server ToolDiffPreview)

struct DiffPreviewInfo {
  let contextLine: String?
  let snippetText: String
  let snippetPrefix: String
  let isAddition: Bool
  let additions: Int
  let deletions: Int

  func barWidths(maxWidth: CGFloat) -> (added: CGFloat, removed: CGFloat) {
    let total = CGFloat(additions + deletions)
    let addedFraction = total > 0 ? CGFloat(additions) / total : 1
    let addedWidth = round(addedFraction * maxWidth)
    let removedWidth = deletions > 0 ? max(0, maxWidth - addedWidth - 1) : 0
    return (addedWidth, removedWidth)
  }
}

// MARK: - Todo Item (from server ToolTodoItem)

struct CompactTodoItem: Hashable {
  let status: NativeTodoStatus
}

// MARK: - The Model

/// Font style for the summary text, computed server-side.
enum SummaryFontStyle {
  case system
  case mono
}

/// Visual weight tier, computed server-side. Drives card visibility,
/// font size, and overall visual presence in the timeline.
enum DisplayTier {
  case prominent  // Question — demands attention, full card, bright
  case standard   // Shell, Edit, Agent — normal card with detail
  case compact    // Read, Glob, Grep — no card, inline, muted
  case minimal    // Skill, Plan, Hook — nearly invisible
}

struct NativeCompactToolRowModel {
  // From server ToolDisplay — these are the rendered fields
  let summary: String
  let subtitle: String?
  let rightMeta: String?
  let glyphSymbol: String
  let glyphColor: PlatformColor
  let toolType: CompactToolType
  let language: String?
  let diffPreview: DiffPreviewInfo?
  let outputPreview: String?
  let liveOutputPreview: String?
  let todoItems: [CompactTodoItem]?
  let summaryFont: SummaryFontStyle
  let displayTier: DisplayTier

  // From message metadata
  let timestamp: Date
  let family: ToolFamily
  let isInProgress: Bool
  let mcpServer: String?

  // Worker linkage (from message + subagent registry)
  let linkedWorkerID: String?
  let linkedWorkerLabel: String?
  let linkedWorkerStatusText: String?
  let isFocusedWorker: Bool
}

// MARK: - Semantic Color Mapping

extension PlatformColor {
  static func fromSemanticName(_ name: String) -> PlatformColor {
    switch name {
    case "toolBash": PlatformColor(Color.toolBash)
    case "toolRead": PlatformColor(Color.toolRead)
    case "toolWrite": PlatformColor(Color.toolWrite)
    case "toolSearch": PlatformColor(Color.toolSearch)
    case "toolTask": PlatformColor(Color.toolTask)
    case "toolQuestion": PlatformColor(Color.toolQuestion)
    case "toolTodo": PlatformColor(Color.toolTodo)
    case "toolPlan": PlatformColor(Color.toolPlan)
    case "toolMcp": PlatformColor(Color.toolMcp)
    case "toolWeb": PlatformColor(Color.toolWeb)
    case "toolSkill": PlatformColor(Color.toolSkill)
    case "feedbackCaution": PlatformColor(Color.feedbackCaution)
    case "feedbackPositive": PlatformColor(Color.feedbackPositive)
    case "feedbackNegative": PlatformColor(Color.feedbackNegative)
    case "feedbackWarning": PlatformColor(Color.feedbackWarning)
    case "statusReply": PlatformColor(Color.statusReply)
    case "statusWorking": PlatformColor(Color.statusWorking)
    case "accent": PlatformColor(Color.accentColor)
    case "secondaryLabel": PlatformColor.secondaryLabelCompat
    default: PlatformColor.secondaryLabelCompat
    }
  }
}

// MARK: - Glyph Info (fallback only — server provides glyph for all tool messages)

struct ToolGlyphInfo {
  let symbol: String
  let color: PlatformColor

  static func from(message: TranscriptMessage) -> ToolGlyphInfo {
    if message.isShell {
      return ToolGlyphInfo(symbol: "terminal", color: PlatformColor(Color.toolBash))
    }
    guard let name = message.toolName else {
      return ToolGlyphInfo(symbol: "gearshape", color: PlatformColor.secondaryLabelCompat)
    }
    if TodoToolOperation(toolName: name) != nil {
      return ToolGlyphInfo(symbol: "checklist", color: PlatformColor(Color.toolTodo))
    }
    if name.hasPrefix("mcp__") {
      return ToolGlyphInfo(symbol: "puzzlepiece.extension", color: PlatformColor(Color.toolMcp))
    }
    switch name.lowercased() {
      case "bash": return ToolGlyphInfo(symbol: "terminal", color: PlatformColor(Color.toolBash))
      case "read": return ToolGlyphInfo(symbol: "doc.plaintext", color: PlatformColor(Color.toolRead))
      case "edit", "write", "notebookedit":
        return ToolGlyphInfo(symbol: "pencil.line", color: PlatformColor(Color.toolWrite))
      case "glob", "grep":
        return ToolGlyphInfo(symbol: "magnifyingglass", color: PlatformColor(Color.toolSearch))
      case "task", "agent", "wait", "send_input", "spawn_agent":
        return ToolGlyphInfo(symbol: "bolt.fill", color: PlatformColor(Color.toolTask))
      case "handoff":
        return ToolGlyphInfo(symbol: "arrow.triangle.branch", color: PlatformColor(Color.statusReply))
      case "hook":
        return ToolGlyphInfo(symbol: "bolt.badge.clock", color: PlatformColor(Color.feedbackCaution))
      case "compactcontext":
        return ToolGlyphInfo(symbol: "arrow.triangle.2.circlepath", color: PlatformColor(Color.accent))
      case "webfetch", "websearch": return ToolGlyphInfo(symbol: "globe", color: PlatformColor(Color.toolWeb))
      case "view_image": return ToolGlyphInfo(symbol: "photo", color: PlatformColor(Color.toolRead))
      case "skill": return ToolGlyphInfo(symbol: "wand.and.stars", color: PlatformColor(Color.toolSkill))
      case "toolsearch", "tool_search":
        return ToolGlyphInfo(symbol: "puzzlepiece.extension", color: PlatformColor(Color.toolSearch))
      case "enterplanmode", "exitplanmode", "plan", "update_plan":
        return ToolGlyphInfo(symbol: "map", color: PlatformColor(Color.toolPlan))
      case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget":
        return ToolGlyphInfo(symbol: "checklist", color: PlatformColor(Color.toolTodo))
      case "askuserquestion", "question":
        return ToolGlyphInfo(symbol: "questionmark.bubble", color: PlatformColor(Color.toolQuestion))
      case "mcp_approval":
        return ToolGlyphInfo(symbol: "shield.lefthalf.filled", color: PlatformColor(Color.toolQuestion))
      default: return ToolGlyphInfo(symbol: "gearshape", color: PlatformColor.secondaryLabelCompat)
    }
  }

  static func taskAgentColor(_ agentType: String) -> PlatformColor {
    switch agentType.lowercased() {
      case "explore": PlatformColor.calibrated(red: 0.4, green: 0.7, blue: 0.95, alpha: 1)
      case "plan": PlatformColor.calibrated(red: 0.6, green: 0.5, blue: 0.9, alpha: 1)
      case "bash": PlatformColor.calibrated(red: 0.35, green: 0.8, blue: 0.5, alpha: 1)
      case "general-purpose": PlatformColor.calibrated(red: 0.45, green: 0.45, blue: 0.95, alpha: 1)
      case "claude-code-guide": PlatformColor.calibrated(red: 0.9, green: 0.6, blue: 0.3, alpha: 1)
      case "linear-project-manager": PlatformColor.calibrated(red: 0.35, green: 0.5, blue: 0.95, alpha: 1)
      default: PlatformColor.calibrated(red: 0.5, green: 0.5, blue: 0.6, alpha: 1)
    }
  }
}
