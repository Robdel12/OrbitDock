//
//  CompactToolHelpers.swift
//  OrbitDock
//
//  Shared compact tool summaries and preview extraction.
//

import Foundation

enum CompactToolHelpers {
  static func displayName(for toolName: String) -> String {
    let lowered = toolName.lowercased()
    let normalized = lowered.split(separator: ":").last.map(String.init) ?? lowered
    switch normalized {
      case "bash": return "Bash"
      case "read": return "Read"
      case "edit": return "Edit"
      case "write": return "Write"
      case "glob": return "Glob"
      case "grep": return "Grep"
      case "task": return "Task"
      case "webfetch": return "Fetch"
      case "websearch": return "Search"
      case "skill": return "Skill"
      case "enterplanmode", "exitplanmode": return "Plan"
      case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan":
        return "Todo"
      case "askuserquestion": return "Question"
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

  static func summary(for message: TranscriptMessage, supportsRichToolingCards: Bool) -> String {
    if message.isShell {
      return String.shellCommandDisplay(from: message.content) ?? message.content
    }
    guard let name = message.toolName else { return "tool" }
    if let todoSummary = TodoToolParser.compactSummary(
      from: message,
      supportsRichToolingCards: supportsRichToolingCards
    ) {
      return todoSummary
    }
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
      case "compactcontext":
        return message.isInProgress ? "Compacting context…" : "Context compacted"
      case "webfetch", "websearch":
        if let query = inputString(message, key: "query") { return query }
        if let url = inputString(message, key: "url") {
          return URL(string: url)?.host ?? url
        }
        return message.content.isEmpty ? name : message.content
      case "view_image":
        if let path = inputString(message, key: "path") {
          return ToolCardStyle.shortenPath(path)
        }
        return message.content.isEmpty ? "view image" : message.content
      case "skill":
        if let skill = inputString(message, key: "skill") { return skill }
        return "skill"
      case "enterplanmode": return "Enter plan mode"
      case "exitplanmode": return "Exit plan mode"
      case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan":
        if let subject = inputString(message, key: "subject") { return subject }
        return name
      case "askuserquestion": return "Asking question"
      case "mcp_approval": return "MCP approval"
      default: return name
    }
  }

  static func rightMeta(for message: TranscriptMessage, supportsRichToolingCards: Bool) -> String? {
    if message.isShell {
      if let duration = message.formattedDuration {
        let prefix = message.bashHasError ? "\u{2717}" : "\u{2713}"
        return "\(prefix) \(duration)"
      }
      if message.isInProgress { return "LIVE" }
      return nil
    }
    guard let name = message.toolName else { return nil }
    if TodoToolOperation(toolName: name) != nil {
      if let payload = TodoToolParser.payload(
        from: message,
        toolName: name,
        supportsRichToolingCards: supportsRichToolingCards
      ), !payload.items.isEmpty {
        let completed = payload.items.filter { $0.status == .completed }.count
        let active = payload.items.filter { $0.status == .inProgress }.count
        if active > 0 { return "\(completed)/\(payload.items.count) · \(active) active" }
        return "\(completed)/\(payload.items.count) done"
      }
      if message.isInProgress { return "LIVE" }
      return nil
    }
    let lowercased = name.lowercased()
    switch lowercased {
      case "bash":
        if let duration = message.formattedDuration {
          let prefix = message.bashHasError ? "\u{2717}" : "\u{2713}"
          return "\(prefix) \(duration)"
        }
        if message.isInProgress { return "LIVE" }
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

  static func diffPreview(for message: TranscriptMessage) -> DiffPreviewInfo? {
    guard let name = message.toolName?.lowercased(),
          ["edit", "write", "notebookedit"].contains(name)
    else { return nil }

    let isWrite = name == "write"
    let diffLines: [DiffLine]
    if isWrite, let wc = message.writeContent {
      diffLines = wc.components(separatedBy: "\n").enumerated().map { index, line in
        DiffLine(type: .added, content: line, oldLineNum: nil, newLineNum: index + 1, prefix: "+")
      }
    } else if let diff = message.unifiedDiff, !diff.isEmpty {
      diffLines = EditCard.extractChangedLines(fromUnifiedDiff: diff)
    } else if message.editOldString != nil || message.editNewString != nil {
      diffLines = EditCard.extractChangedLines(
        oldString: message.editOldString ?? "",
        newString: message.editNewString ?? ""
      )
    } else {
      return nil
    }

    let additions = diffLines.filter { $0.type == .added }.count
    let deletions = diffLines.filter { $0.type == .removed }.count
    guard additions > 0 || deletions > 0 else { return nil }

    let snippetLine = diffLines.first(where: { $0.type == .added })
      ?? diffLines.first(where: { $0.type == .removed })

    let snippetText: String
    let snippetPrefix: String
    let isAddition: Bool

    if let line = snippetLine {
      let trimmed = line.content.trimmingCharacters(in: .whitespaces)
      let truncated = trimmed.count > 80 ? String(trimmed.prefix(80)) + "\u{2026}" : trimmed

      if isWrite, message.editOldString == nil, trimmed.isEmpty {
        snippetText = "NEW FILE \u{00B7} \(additions) lines"
        snippetPrefix = "+"
        isAddition = true
      } else {
        snippetText = truncated
        snippetPrefix = line.type == .added ? "+" : "-"
        isAddition = line.type == .added
      }
    } else {
      return nil
    }

    let contextLine = contextLineNearChange(message: message, isWrite: isWrite)

    return DiffPreviewInfo(
      contextLine: contextLine,
      snippetText: snippetText,
      snippetPrefix: snippetPrefix,
      isAddition: isAddition,
      additions: additions,
      deletions: deletions
    )
  }

  private static func contextLineNearChange(message: TranscriptMessage, isWrite: Bool) -> String? {
    if isWrite { return nil }

    if let diff = message.unifiedDiff, !diff.isEmpty {
      let parsed = DiffModel.parse(unifiedDiff: diff)
      let allLines = parsed.files.flatMap { $0.hunks.flatMap(\.lines) }
      guard let firstChangeIdx = allLines.firstIndex(where: { $0.type != .context }) else {
        return nil
      }
      if firstChangeIdx > 0, allLines[firstChangeIdx - 1].type == .context {
        return truncateContext(allLines[firstChangeIdx - 1].content)
      }
      if let lastChangeIdx = allLines.lastIndex(where: { $0.type != .context }),
         lastChangeIdx + 1 < allLines.count,
         allLines[lastChangeIdx + 1].type == .context
      {
        return truncateContext(allLines[lastChangeIdx + 1].content)
      }
      return nil
    }

    if let oldString = message.editOldString, let newString = message.editNewString {
      let oldLines = oldString.components(separatedBy: "\n")
      let newLines = newString.components(separatedBy: "\n")

      let commonPrefix = zip(oldLines, newLines).prefix(while: { $0 == $1 }).count
      if commonPrefix > 0 {
        return truncateContext(oldLines[commonPrefix - 1])
      }

      let difference = newLines.difference(from: oldLines)
      var removedOffsets = Set<Int>()
      for change in difference {
        if case let .remove(offset, _, _) = change {
          removedOffsets.insert(offset)
        }
      }

      for (index, line) in oldLines.enumerated() where !removedOffsets.contains(index) {
        if let context = truncateContext(line) {
          return context
        }
      }
    }

    return nil
  }

  private static func truncateContext(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count > 80 {
      return String(trimmed.prefix(80)) + "\u{2026}"
    }
    return trimmed
  }

  static func mcpPrimaryParameter(message: TranscriptMessage) -> String? {
    guard let input = message.toolInput else { return nil }
    let priorityKeys = ["query", "url", "path", "owner", "repo", "message", "title", "name"]

    func firstParameter(from dictionary: [String: Any]) -> String? {
      for key in priorityKeys {
        if let value = dictionary[key], let string = value as? String, !string.isEmpty, string != "<null>" {
          return string.count > 60 ? String(string.prefix(60)) + "..." : string
        }
      }
      for (_, value) in dictionary {
        if let string = value as? String, !string.isEmpty {
          return string.count > 60 ? String(string.prefix(60)) + "..." : string
        }
      }
      return nil
    }

    if let args = input["arguments"] as? [String: Any],
       let nested = firstParameter(from: args)
    {
      return nested
    }

    return firstParameter(from: input)
  }

  static func inputString(_ message: TranscriptMessage, key: String) -> String? {
    guard let input = message.toolInput else { return nil }
    if let value = input[key] as? String, !value.isEmpty, value != "<null>" {
      return value
    }
    if let args = input["arguments"] as? [String: Any],
       let value = args[key] as? String,
       !value.isEmpty,
       value != "<null>"
    {
      return value
    }
    return nil
  }

  static func subtitle(
    for message: TranscriptMessage,
    toolType: CompactToolType,
    rightMeta: String?,
    supportsRichToolingCards: Bool
  ) -> String? {
    switch toolType {
      case .read: return rightMeta
      case .glob: return rightMeta
      case .grep: return rightMeta
      case .task:
        if message.isInProgress { return "Running" }
        if let description = message.taskDescription {
          return description.count > 60 ? String(description.prefix(60)) + "…" : description
        }
        return nil
      case .todo: return rightMeta
      case .mcp: return mcpPrimaryParameter(message: message)
      default: return nil
    }
  }

  static func subtitleAbsorbsMeta(_ toolType: CompactToolType) -> Bool {
    switch toolType {
      case .read, .glob, .grep, .todo: return true
      default: return false
    }
  }

  static func toolType(for message: TranscriptMessage) -> CompactToolType {
    if message.isShell { return .bash }
    guard let name = message.toolName?.lowercased() else { return .generic }
    if TodoToolOperation(toolName: name) != nil { return .todo }
    if name.hasPrefix("mcp__") { return .mcp }
    switch name {
      case "bash": return .bash
      case "read": return .read
      case "edit", "write", "notebookedit": return .edit
      case "glob": return .glob
      case "grep": return .grep
      case "task": return .task
      case "webfetch", "websearch": return .web
      case "enterplanmode", "exitplanmode": return .plan
      case "askuserquestion": return .question
      case "skill": return .skill
      default: return .generic
    }
  }

  static func outputPreview(for message: TranscriptMessage) -> String? {
    let toolType = toolType(for: message)
    switch toolType {
      case .bash:
        guard !message.isInProgress else { return nil }
        guard let output = message.sanitizedToolOutput, !output.isEmpty else { return nil }
        return lastNLines(output, n: 3)
      case .glob:
        guard let output = message.toolOutput, !output.isEmpty else { return nil }
        return globDirectorySummary(output)
      case .grep:
        guard let output = message.toolOutput, !output.isEmpty else { return nil }
        return firstGrepMatch(output)
      case .task:
        return message.taskDescription ?? message.taskPrompt
      case .mcp:
        return mcpPrimaryParameter(message: message)
      default:
        return nil
    }
  }

  static func detectedLanguage(for message: TranscriptMessage) -> String? {
    guard message.toolName?.lowercased() == "read", let path = message.filePath else { return nil }
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
      case "swift": return "Swift"
      case "ts", "tsx": return "TypeScript"
      case "js", "jsx": return "JavaScript"
      case "py": return "Python"
      case "rs": return "Rust"
      case "go": return "Go"
      case "rb": return "Ruby"
      case "md": return "Markdown"
      case "json": return "JSON"
      case "yaml", "yml": return "YAML"
      case "toml": return "TOML"
      case "sh", "bash", "zsh": return "Shell"
      case "css", "scss": return "CSS"
      case "html": return "HTML"
      case "xml": return "XML"
      case "sql": return "SQL"
      case "kt": return "Kotlin"
      case "java": return "Java"
      case "c", "h": return "C"
      case "cpp", "hpp", "cc": return "C++"
      case "m", "mm": return "Obj-C"
      default: return nil
    }
  }

  static func mcpServerName(for message: TranscriptMessage) -> String? {
    guard let name = message.toolName, name.hasPrefix("mcp__") else { return nil }
    let stripped = name.replacingOccurrences(of: "mcp__", with: "")
    return stripped.components(separatedBy: "__").first
  }

  static func compactTodoItems(
    for message: TranscriptMessage,
    supportsRichToolingCards: Bool
  ) -> [CompactTodoItem]? {
    guard let name = message.toolName, TodoToolOperation(toolName: name) != nil else { return nil }
    guard let payload = TodoToolParser.payload(
      from: message,
      toolName: name,
      supportsRichToolingCards: supportsRichToolingCards
    ), !payload.items.isEmpty else { return nil }
    return payload.items.map { CompactTodoItem(status: $0.status) }
  }

  private static func lastNLines(_ text: String, n: Int) -> String? {
    let lines = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return nil }
    let taken = lines.suffix(n)
    return taken.map { line in
      line.count > 80 ? String(line.prefix(80)) + "…" : line
    }.joined(separator: "\n")
  }

  private static func globDirectorySummary(_ output: String) -> String? {
    let files = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard !files.isEmpty else { return nil }

    var counts: [String: Int] = [:]
    var order: [String] = []
    for file in files {
      let components = file.components(separatedBy: "/")
      let directory = components.count > 1 ? components.dropLast().joined(separator: "/") : "."
      if counts[directory] == nil { order.append(directory) }
      counts[directory, default: 0] += 1
    }

    let grouped = order.map { directory in
      (ToolCardStyle.shortenPath(directory), counts[directory] ?? 0)
    }

    let display = grouped.prefix(3).map { "\($0.0) (\($0.1))" }.joined(separator: ", ")
    if grouped.count > 3 {
      return display + " +\(grouped.count - 3) more"
    }
    return display
  }

  private static func firstGrepMatch(_ output: String) -> String? {
    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard let firstMatch = lines.first else { return nil }
    return firstMatch.count > 80 ? String(firstMatch.prefix(80)) + "…" : firstMatch
  }

  static func liveOutputPreview(for message: TranscriptMessage) -> String? {
    guard message.toolName?.lowercased() == "bash" || message.isShell, message.isInProgress else { return nil }

    let output = (message.sanitizedToolOutput ?? "")
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    let lastLine = output
      .components(separatedBy: "\n")
      .reversed()
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    let preview = (lastLine ?? "running...")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !preview.isEmpty else { return "running..." }
    if preview.count > 96 {
      return String(preview.prefix(96)) + "\u{2026}"
    }
    return preview
  }
}
