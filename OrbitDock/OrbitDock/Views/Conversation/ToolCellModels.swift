//
//  ToolCellModels.swift
//  OrbitDock
//
//  Cross-platform model types and shared model builders for timeline cells.
//  Used by both macOS (NSTableView cells) and iOS (UICollectionView cells).
//

import SwiftUI

// MARK: - Compact Tool Row Model

struct NativeCompactToolRowModel {
  let timestamp: Date
  let glyphSymbol: String
  let glyphColor: PlatformColor
  let summary: String
  let rightMeta: String?
  let isInProgress: Bool
}

// MARK: - Tool Glyph Info

struct ToolGlyphInfo {
  let symbol: String
  let color: PlatformColor

  static func from(message: TranscriptMessage) -> ToolGlyphInfo {
    guard let name = message.toolName else {
      return ToolGlyphInfo(symbol: "gearshape", color: PlatformColor.secondaryLabelCompat)
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
      case "webfetch", "websearch": return ToolGlyphInfo(symbol: "globe", color: PlatformColor(Color.toolWeb))
      case "skill": return ToolGlyphInfo(symbol: "wand.and.stars", color: PlatformColor(Color.toolSkill))
      case "enterplanmode", "exitplanmode":
        return ToolGlyphInfo(symbol: "map", color: PlatformColor(Color.toolPlan))
      case "taskcreate", "taskupdate", "tasklist", "taskget":
        return ToolGlyphInfo(symbol: "checklist", color: PlatformColor(Color.toolTodo))
      case "askuserquestion":
        return ToolGlyphInfo(symbol: "questionmark.bubble", color: PlatformColor(Color.toolQuestion))
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

// MARK: - Compact Tool Helpers

enum CompactToolHelpers {
  static func summary(for message: TranscriptMessage) -> String {
    guard let name = message.toolName else { return "tool" }
    let lowercased = name.lowercased()
    if name.hasPrefix("mcp__") {
      return name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " \u{00B7} ")
    }
    switch lowercased {
      case "bash": return message.bashCommand ?? "bash"
      case "read": return message.filePath.map { ToolCardStyle.shortenPath($0) } ?? "read"
      case "edit", "write", "notebookedit":
        return message.filePath.map { ToolCardStyle.shortenPath($0) } ?? name
      case "glob": return message.globPattern ?? "glob"
      case "grep": return message.grepPattern ?? "grep"
      case "task": return message.taskDescription ?? message.taskPrompt ?? "task"
      case "webfetch", "websearch":
        if let input = message.toolInput, let query = input["query"] as? String { return query }
        if let input = message.toolInput, let url = input["url"] as? String {
          return URL(string: url)?.host ?? url
        }
        return name
      case "skill":
        if let input = message.toolInput, let skill = input["skill"] as? String { return skill }
        return "skill"
      case "enterplanmode": return "Enter plan mode"
      case "exitplanmode": return "Exit plan mode"
      case "taskcreate", "taskupdate", "tasklist", "taskget":
        if let input = message.toolInput, let subject = input["subject"] as? String { return subject }
        return name
      case "askuserquestion": return "Asking question"
      default: return name
    }
  }

  static func rightMeta(for message: TranscriptMessage) -> String? {
    guard let name = message.toolName else { return nil }
    let lowercased = name.lowercased()
    switch lowercased {
      case "bash":
        if let dur = message.formattedDuration {
          let prefix = message.bashHasError ? "\u{2717}" : "\u{2713}"
          return "\(prefix) \(dur)"
        }
        if message.isInProgress { return "\u{2026}" }
        return nil
      case "read":
        if let count = message.outputLineCount { return "\(count) lines" }
        return nil
      case "edit", "write", "notebookedit":
        if let old = message.editOldString, let new = message.editNewString {
          let oldLines = old.components(separatedBy: "\n").count
          let newLines = new.components(separatedBy: "\n").count
          let added = max(0, newLines - oldLines)
          let removed = max(0, oldLines - newLines)
          if added > 0 || removed > 0 { return "+\(added) -\(removed)" }
          return "~\(newLines) lines"
        }
        if message.hasUnifiedDiff, let diff = message.unifiedDiff {
          let lines = diff.components(separatedBy: "\n")
          let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
          let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
          return "+\(added) -\(removed)"
        }
        return nil
      case "glob":
        if let count = message.globMatchCount { return "\(count) files" }
        return nil
      case "grep":
        if let count = message.grepMatchCount { return "\(count) matches" }
        return nil
      default:
        return nil
    }
  }

  static func mcpPrimaryParameter(message: TranscriptMessage) -> String? {
    guard let input = message.toolInput else { return nil }
    let priorityKeys = ["query", "url", "path", "owner", "repo", "message", "title", "name"]
    for key in priorityKeys {
      if let value = input[key], let str = value as? String, !str.isEmpty, str != "<null>" {
        return str.count > 60 ? String(str.prefix(60)) + "..." : str
      }
    }
    for (_, value) in input {
      if let str = value as? String, !str.isEmpty {
        return str.count > 60 ? String(str.prefix(60)) + "..." : str
      }
    }
    return nil
  }
}

// MARK: - Shared Model Builders

/// Cross-platform model builders used by both macOS and iOS timeline cells.
/// Extracts duplicated logic so both platforms call the same functions.
enum SharedModelBuilders {

  // MARK: Rich Message

  static func richMessageModel(
    from message: TranscriptMessage,
    messageID: String,
    isThinkingExpanded: Bool
  ) -> NativeRichMessageRowModel? {
    guard !message.isTool else { return nil }
    guard !message.content.isEmpty else { return nil }

    let messageType: NativeRichMessageRowModel.MessageType
    let speaker: String

    if message.isUser {
      messageType = .user
      speaker = "YOU"
    } else if message.isThinking {
      messageType = .thinking
      speaker = "REASONING"
    } else if message.isSteer {
      messageType = .steer
      speaker = "STEER"
    } else if message.isShell {
      messageType = .shell
      speaker = "YOU"
    } else {
      messageType = .assistant
      speaker = "ASSISTANT"
    }

    return NativeRichMessageRowModel(
      messageID: messageID,
      speaker: speaker,
      content: message.content,
      thinking: message.thinking,
      messageType: messageType,
      timestamp: message.timestamp,
      hasImages: message.hasImage,
      images: message.images,
      isThinkingExpanded: isThinkingExpanded
    )
  }

  // MARK: Compact Tool

  static func compactToolModel(from message: TranscriptMessage) -> NativeCompactToolRowModel {
    let glyph = ToolGlyphInfo.from(message: message)
    let summary = CompactToolHelpers.summary(for: message)
    let meta = CompactToolHelpers.rightMeta(for: message)

    return NativeCompactToolRowModel(
      timestamp: message.timestamp,
      glyphSymbol: glyph.symbol,
      glyphColor: glyph.color,
      summary: summary,
      rightMeta: meta,
      isInProgress: message.isInProgress
    )
  }

  // MARK: Expanded Tool

  static func expandedToolModel(
    from message: TranscriptMessage,
    messageID: String
  ) -> NativeExpandedToolModel {
    let glyph = ToolGlyphInfo.from(message: message)
    let toolName = message.toolName ?? "tool"
    let content = expandedToolContent(from: message, toolName: toolName)

    return NativeExpandedToolModel(
      messageID: messageID,
      toolColor: glyph.color,
      iconName: ToolCardStyle.icon(for: toolName),
      hasError: message.bashHasError,
      isInProgress: message.isInProgress,
      duration: message.formattedDuration,
      content: content
    )
  }

  /// Build the NativeToolContent for an expanded tool card.
  /// This is the big switch statement that was duplicated on both platforms.
  static func expandedToolContent(from message: TranscriptMessage, toolName: String) -> NativeToolContent {
    let lowercased = toolName.lowercased()

    switch lowercased {
      case "bash":
        return .bash(
          command: message.bashCommand ?? message.content,
          output: message.sanitizedToolOutput
        )

      case "edit", "write", "notebookedit":
        let filename = message.filePath?.components(separatedBy: "/").last
        let isWrite = lowercased == "write"
        let diffLines: [DiffLine] = if isWrite, let wc = message.writeContent {
          wc.components(separatedBy: "\n").enumerated().map { index, line in
            DiffLine(type: .added, content: line, oldLineNum: nil, newLineNum: index + 1, prefix: "+")
          }
        } else if let diff = message.unifiedDiff, !diff.isEmpty {
          EditCard.extractChangedLines(fromUnifiedDiff: diff)
        } else {
          EditCard.extractChangedLines(
            oldString: message.editOldString ?? "",
            newString: message.editNewString ?? ""
          )
        }
        let additions = diffLines.filter { $0.type == .added }.count
        let deletions = diffLines.filter { $0.type == .removed }.count
        return .edit(
          filename: filename,
          path: message.filePath,
          additions: additions,
          deletions: deletions,
          lines: diffLines,
          isWriteNew: isWrite && message.editOldString == nil
        )

      case "read":
        let output = message.toolOutput ?? ""
        let lines = output.components(separatedBy: "\n")
        let language = ToolCardStyle.detectLanguage(from: message.filePath)
        let filename = message.filePath?.components(separatedBy: "/").last
        return .read(filename: filename, path: message.filePath, language: language, lines: lines)

      case "glob":
        let output = message.toolOutput ?? ""
        let files = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        let grouped = Dictionary(grouping: files) { path -> String in
          let comps = path.components(separatedBy: "/")
          return comps.count > 1 ? comps.dropLast().joined(separator: "/") : "."
        }.map { (dir: $0.key, files: $0.value) }.sorted { $0.dir < $1.dir }
        return .glob(pattern: message.globPattern ?? "**/*", grouped: grouped)

      case "grep":
        let output = message.toolOutput ?? ""
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        let isFileList = lines.first.map { !$0.contains(":") } ?? true
        let grouped: [(file: String, matches: [String])]
        if isFileList {
          grouped = lines.map { (file: $0, matches: []) }
        } else {
          var fileMatches: [String: [String]] = [:]
          for line in lines {
            let parts = line.split(separator: ":", maxSplits: 2)
            if parts.count >= 2 {
              let file = String(parts[0])
              let match = parts.count > 2 ? String(parts[1]) + ":" + String(parts[2]) : String(parts[1])
              fileMatches[file, default: []].append(match)
            }
          }
          grouped = fileMatches.keys.sorted().map { (file: $0, matches: fileMatches[$0] ?? []) }
        }
        return .grep(pattern: message.grepPattern ?? "", grouped: grouped)

      case "task":
        let agentType = (message.toolInput?["subagent_type"] as? String) ?? "general"
        let agentLabel = agentType.isEmpty ? "Agent" : agentType.capitalized
        let agentColor = ToolGlyphInfo.taskAgentColor(agentType)
        let isComplete = !message.isInProgress && !(message.toolOutput ?? "").isEmpty
        return .task(
          agentLabel: agentLabel,
          agentColor: agentColor,
          description: message.taskDescription ?? "",
          output: message.sanitizedToolOutput,
          isComplete: isComplete
        )

      default:
        if toolName.hasPrefix("mcp__") {
          let parts = toolName.dropFirst(5).split(separator: "__", maxSplits: 1)
          let server = parts.count >= 1 ? String(parts[0]) : "mcp"
          let tool = parts.count >= 2 ? String(parts[1]) : toolName
          let displayTool = tool.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map(\.capitalized).joined(separator: " ")
          let subtitle = CompactToolHelpers.mcpPrimaryParameter(message: message)
          return .mcp(
            server: server,
            displayTool: displayTool,
            subtitle: subtitle,
            output: message.sanitizedToolOutput
          )
        } else if lowercased == "webfetch" {
          let url = (message.toolInput?["url"] as? String) ?? ""
          let domain = URL(string: url)?.host ?? url
          return .webFetch(domain: domain, url: url, output: message.sanitizedToolOutput)
        } else if lowercased == "websearch" {
          let query = (message.toolInput?["query"] as? String) ?? ""
          return .webSearch(query: query, output: message.sanitizedToolOutput)
        } else {
          return .generic(
            toolName: toolName,
            input: message.formattedToolInput,
            output: message.sanitizedToolOutput
          )
        }
    }
  }
}
