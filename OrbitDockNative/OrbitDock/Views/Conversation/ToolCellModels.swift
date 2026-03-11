//
//  ToolCellModels.swift
//  OrbitDock
//
//  Shared model builders used by both AppKit and UIKit conversation rows.
//

import Foundation

enum SharedModelBuilders {

  static func richMessageModel(
    from message: TranscriptMessage,
    messageID: String,
    isThinkingExpanded: Bool,
    showHeader: Bool = true
  ) -> NativeRichMessageRowModel? {
    guard !message.isTool else { return nil }

    let displayContent: String = if message.isUser {
      preprocessUserContent(message.content)
    } else {
      message.content
    }

    let hasRenderableBody = !displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if !hasRenderableBody, message.images.isEmpty {
      return nil
    }

    let messageType: NativeRichMessageRowModel.MessageType
    let speaker: String
    let renderMode: NativeRichMessageRowModel.RenderMode

    if message.isUser {
      messageType = .user
      speaker = "YOU"
      renderMode = .markdown
    } else if message.isThinking {
      messageType = .thinking
      speaker = "REASONING"
      renderMode = message.isInProgress ? .streamingPlainText : .markdown
    } else if message.isSteer {
      messageType = .steer
      speaker = "STEER"
      renderMode = .markdown
    } else if message.isShell {
      messageType = .shell
      speaker = "YOU"
      renderMode = .markdown
    } else if message.isError, message.isAssistant {
      messageType = .error
      speaker = "ERROR"
      renderMode = .markdown
    } else {
      messageType = .assistant
      speaker = "ASSISTANT"
      renderMode = message.isInProgress ? .streamingPlainText : .markdown
    }

    return NativeRichMessageRowModel(
      messageID: messageID,
      speaker: speaker,
      content: displayContent,
      thinking: message.thinking,
      messageType: messageType,
      renderMode: renderMode,
      timestamp: message.timestamp,
      hasImages: message.hasImage,
      images: message.images,
      isThinkingExpanded: isThinkingExpanded,
      showHeader: showHeader
    )
  }

  static func compactToolModel(
    from message: TranscriptMessage,
    supportsRichToolingCards: Bool
  ) -> NativeCompactToolRowModel {
    let glyph = ToolGlyphInfo.from(message: message)
    let toolType = CompactToolHelpers.toolType(for: message)
    let summary = CompactToolHelpers.compactSingleLineSummary(
      CompactToolHelpers.summary(for: message, supportsRichToolingCards: supportsRichToolingCards)
    )
    var meta = CompactToolHelpers.rightMeta(for: message, supportsRichToolingCards: supportsRichToolingCards)
    let preview = CompactToolHelpers.diffPreview(for: message)
    let liveOutputPreview = CompactToolHelpers.liveOutputPreview(for: message)
    let outputPreview = CompactToolHelpers.outputPreview(for: message)
    let language = CompactToolHelpers.detectedLanguage(for: message)
    let mcpServer = CompactToolHelpers.mcpServerName(for: message)
    let todoItems = CompactToolHelpers.compactTodoItems(for: message, supportsRichToolingCards: supportsRichToolingCards)

    if toolType == .read, let lang = language, let existing = meta {
      meta = "\(existing) · \(lang)"
    } else if toolType == .read, let lang = language {
      meta = lang
    }

    let subtitle = CompactToolHelpers.subtitle(
      for: message,
      toolType: toolType,
      rightMeta: meta,
      supportsRichToolingCards: supportsRichToolingCards
    )
    if CompactToolHelpers.subtitleAbsorbsMeta(toolType), subtitle != nil {
      meta = nil
    }

    return NativeCompactToolRowModel(
      timestamp: message.timestamp,
      glyphSymbol: glyph.symbol,
      glyphColor: glyph.color,
      summary: summary,
      subtitle: subtitle,
      rightMeta: meta,
      linkedWorkerID: linkedWorkerID(for: message),
      isInProgress: message.isInProgress,
      diffPreview: preview,
      liveOutputPreview: liveOutputPreview,
      toolType: toolType,
      outputPreview: outputPreview,
      language: language,
      mcpServer: mcpServer,
      todoItems: todoItems
    )
  }

  static func expandedToolModel(
    from message: TranscriptMessage,
    messageID: String,
    supportsRichToolingCards: Bool
  ) -> NativeExpandedToolModel {
    let glyph = ToolGlyphInfo.from(message: message)
    let toolName = message.toolName ?? (message.isShell ? "bash" : "tool")
    let content = expandedToolContent(
      from: message,
      toolName: toolName,
      supportsRichToolingCards: supportsRichToolingCards
    )

    return NativeExpandedToolModel(
      messageID: messageID,
      toolColor: glyph.color,
      iconName: ToolCardStyle.icon(for: toolName),
      hasError: message.bashHasError,
      isInProgress: message.isInProgress,
      canCancel: (message.isShell || toolName.lowercased() == "task") && message.isInProgress,
      duration: message.formattedDuration,
      linkedWorkerID: linkedWorkerID(for: message),
      content: content
    )
  }

  static func linkedWorkerID(for message: TranscriptMessage) -> String? {
    if let explicitSubagentID = message.toolInput?["subagent_id"] as? String,
       !explicitSubagentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return explicitSubagentID
    }

    if let receiverThreadID = message.toolInput?["receiver_thread_id"] as? String,
       !receiverThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return receiverThreadID
    }

    if let receiverThreadIDs = message.toolInput?["receiver_thread_ids"] as? [String],
       receiverThreadIDs.count == 1
    {
      let onlyThreadID = receiverThreadIDs[0].trimmingCharacters(in: .whitespacesAndNewlines)
      return onlyThreadID.isEmpty ? nil : onlyThreadID
    }

    return nil
  }

  private static func preprocessUserContent(_ content: String) -> String {
    if let cmd = ParsedSlashCommand.parse(from: content) {
      var result = cmd.name
      if cmd.hasArgs { result += " " + cmd.args.trimmingCharacters(in: .whitespacesAndNewlines) }
      if cmd.hasOutput { result += "\n\n" + cmd.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
      return result
    }

    if content.contains("<local-command-stderr>") {
      let stderr = extractTag("local-command-stderr", from: content)
      if !stderr.isEmpty { return stderr }
    }

    if let bash = ParsedBashContent.parse(from: content) {
      var parts: [String] = []
      if bash.hasInput { parts.append("$ " + bash.input) }
      if !bash.stdout.isEmpty { parts.append(bash.stdout) }
      if !bash.stderr.isEmpty { parts.append(bash.stderr) }
      return parts.joined(separator: "\n")
    }

    if ParsedSystemContext.parse(from: content) != nil { return "" }
    guard content.contains("<") else { return content }

    let stripped = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func expandedToolContent(
    from message: TranscriptMessage,
    toolName: String,
    supportsRichToolingCards: Bool
  ) -> NativeToolContent {
    let lowercased = toolName.lowercased()
    if let payload = TodoToolParser.payload(
      from: message,
      toolName: toolName,
      supportsRichToolingCards: supportsRichToolingCards
    ) {
      return .todo(
        title: payload.title,
        subtitle: payload.subtitle,
        items: payload.items,
        output: payload.output
      )
    }

    switch lowercased {
      case "bash":
        return .bash(
          command: message.bashCommand ?? message.content,
          input: message.bashMetadataInput,
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
          EditCard.extractAllLines(fromUnifiedDiff: diff)
        } else {
          EditCard.extractLinesWithContext(
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
          let components = path.components(separatedBy: "/")
          return components.count > 1 ? components.dropLast().joined(separator: "/") : "."
        }
        .map { (dir: $0.key, files: $0.value) }
        .sorted { $0.dir < $1.dir }
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

      case "compactcontext":
        return .generic(
          toolName: "Compact Context",
          input: message.fullFormattedToolInput,
          output: message.sanitizedToolOutput
        )

      case "askuserquestion":
        return .generic(
          toolName: "Question",
          input: message.fullFormattedToolInput,
          output: message.sanitizedToolOutput
        )

      case "mcp_approval":
        return .generic(
          toolName: "MCP Approval",
          input: message.fullFormattedToolInput,
          output: message.sanitizedToolOutput
        )

      default:
        if toolName.hasPrefix("mcp__") {
          let parts = toolName.dropFirst(5).split(separator: "__", maxSplits: 1)
          let server = parts.count >= 1 ? String(parts[0]) : "mcp"
          let tool = parts.count >= 2 ? String(parts[1]) : toolName
          let displayTool = tool
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(\.capitalized)
            .joined(separator: " ")
          let subtitle = CompactToolHelpers.mcpPrimaryParameter(message: message)
          return .mcp(
            server: server,
            displayTool: displayTool,
            subtitle: subtitle,
            input: message.fullFormattedToolInput,
            output: message.sanitizedToolOutput
          )
        } else if lowercased == "webfetch" {
          let url = CompactToolHelpers.inputString(message, key: "url") ?? ""
          let domain = URL(string: url)?.host ?? url
          return .webFetch(
            domain: domain,
            url: url,
            input: message.fullFormattedToolInput,
            output: message.sanitizedToolOutput
          )
        } else if lowercased == "websearch" {
          let query = (CompactToolHelpers.inputString(message, key: "query")?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? message.content
          return .webSearch(
            query: query,
            input: message.fullFormattedToolInput,
            output: message.sanitizedToolOutput
          )
        } else {
          return .generic(
            toolName: toolName,
            input: message.fullFormattedToolInput,
            output: message.sanitizedToolOutput
          )
        }
    }
  }
}
