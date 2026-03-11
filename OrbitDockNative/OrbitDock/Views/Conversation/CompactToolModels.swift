//
//  CompactToolModels.swift
//  OrbitDock
//
//  Shared compact tool model types and glyph metadata.
//

import SwiftUI

nonisolated enum CompactToolType: Hashable, Sendable {
  case bash, read, edit, glob, grep, task, todo, mcp, web, plan, question, skill, handoff, hook, generic
}

struct CompactTodoItem: Hashable {
  let status: NativeTodoStatus
}

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

struct NativeCompactToolRowModel {
  let timestamp: Date
  let glyphSymbol: String
  let glyphColor: PlatformColor
  let summary: String
  let subtitle: String?
  let rightMeta: String?
  let linkedWorkerID: String?
  let linkedWorkerLabel: String?
  let linkedWorkerStatusText: String?
  let isFocusedWorker: Bool
  let isInProgress: Bool
  let diffPreview: DiffPreviewInfo?
  let liveOutputPreview: String?
  let toolType: CompactToolType
  let outputPreview: String?
  let language: String?
  let mcpServer: String?
  let todoItems: [CompactTodoItem]?
}

extension NativeCompactToolRowModel {
  static func requiredHeight(for model: NativeCompactToolRowModel, width: CGFloat) -> CGFloat {
    let base: CGFloat = 40

    if model.diffPreview != nil {
      let contextExtra: CGFloat = model.diffPreview?.contextLine != nil ? 15 : 0
      return base + 22 + contextExtra
    }
    if model.liveOutputPreview != nil { return base + 17 }
    if let items = model.todoItems, !items.isEmpty { return base + 17 }
    if let preview = model.outputPreview {
      let lineCount = min(preview.components(separatedBy: "\n").count, 3)
      return base + CGFloat(lineCount) * 15
    }
    return base
  }
}

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
      case "task": return ToolGlyphInfo(symbol: "bolt.fill", color: PlatformColor(Color.toolTask))
      case "handoff":
        return ToolGlyphInfo(symbol: "arrow.triangle.branch", color: PlatformColor(Color.statusReply))
      case "hook":
        return ToolGlyphInfo(symbol: "bolt.badge.clock", color: PlatformColor(Color.feedbackCaution))
      case "compactcontext":
        return ToolGlyphInfo(symbol: "arrow.triangle.2.circlepath", color: PlatformColor(Color.accent))
      case "webfetch", "websearch": return ToolGlyphInfo(symbol: "globe", color: PlatformColor(Color.toolWeb))
      case "view_image": return ToolGlyphInfo(symbol: "photo", color: PlatformColor(Color.toolRead))
      case "skill": return ToolGlyphInfo(symbol: "wand.and.stars", color: PlatformColor(Color.toolSkill))
      case "enterplanmode", "exitplanmode":
        return ToolGlyphInfo(symbol: "map", color: PlatformColor(Color.toolPlan))
      case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan":
        return ToolGlyphInfo(symbol: "checklist", color: PlatformColor(Color.toolTodo))
      case "askuserquestion":
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
