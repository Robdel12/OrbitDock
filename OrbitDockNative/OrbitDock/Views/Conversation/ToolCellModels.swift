//
//  ToolCellModels.swift
//  OrbitDock
//
//  Shared model builders used by both AppKit and UIKit conversation rows.
//

import Foundation
import SwiftUI
import SwiftUI

enum SharedModelBuilders {
  private struct WorkerLinkPresentation {
    let id: String
    let label: String
    let statusText: String
    let detailText: String?
  }

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
    supportsRichToolingCards: Bool,
    subagentsByID: [String: ServerSubagentInfo] = [:]
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
    let workerPresentation = linkedWorkerPresentation(for: message, subagentsByID: subagentsByID)

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
    let workerSubtitle = workerPresentation.map { "\($0.label) · \($0.statusText)" }
    let mergedSubtitle = mergeSubtitle(primary: subtitle, workerSubtitle: workerSubtitle)
    let fallbackPreview = fallbackWorkerPreview(
      summary: summary,
      subtitle: mergedSubtitle,
      existingPreview: outputPreview,
      workerPresentation: workerPresentation
    )
    if CompactToolHelpers.subtitleAbsorbsMeta(toolType), subtitle != nil {
      meta = nil
    }

    return NativeCompactToolRowModel(
      timestamp: message.timestamp,
      glyphSymbol: glyph.symbol,
      glyphColor: glyph.color,
      summary: summary,
      subtitle: mergedSubtitle,
      rightMeta: meta,
      linkedWorkerID: linkedWorkerID(for: message),
      linkedWorkerLabel: workerPresentation?.label,
      linkedWorkerStatusText: workerPresentation?.statusText,
      isInProgress: message.isInProgress,
      diffPreview: preview,
      liveOutputPreview: liveOutputPreview,
      toolType: toolType,
      outputPreview: fallbackPreview,
      language: language,
      mcpServer: mcpServer,
      todoItems: todoItems
    )
  }

  static func expandedToolModel(
    from message: TranscriptMessage,
    messageID: String,
    supportsRichToolingCards: Bool,
    subagentsByID: [String: ServerSubagentInfo] = [:]
  ) -> NativeExpandedToolModel {
    let glyph = ToolGlyphInfo.from(message: message)
    let toolName = message.toolName ?? (message.isShell ? "bash" : "tool")
    let content = expandedToolContent(
      from: message,
      toolName: toolName,
      supportsRichToolingCards: supportsRichToolingCards,
      subagentsByID: subagentsByID
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

  static func workerEventModel(
    from message: TranscriptMessage,
    subagentsByID: [String: ServerSubagentInfo] = [:]
  ) -> NativeCompactToolRowModel? {
    guard let workerID = linkedWorkerID(for: message) else { return nil }

    let worker = subagentsByID[workerID]
    let workerLabel = trimmed(worker?.label)
      ?? trimmed(worker?.agentType)?.capitalized
      ?? "Worker"
    let statusText = workerStatusText(worker?.status, message: message)
    let eventLabel = workerEventLabel(for: message)
    let summary = workerLabel
    let subtitle = trimmed(
      [eventLabel, workerEventSummary(for: message)]
        .compactMap(trimmed)
        .joined(separator: " · ")
    )
    let reportPreview = workerReportPreview(for: message)

    return NativeCompactToolRowModel(
      timestamp: message.timestamp,
      glyphSymbol: workerGlyphSymbol(for: worker),
      glyphColor: workerGlyphColor(for: worker, message: message),
      summary: summary,
      subtitle: subtitle,
      rightMeta: statusText,
      linkedWorkerID: workerID,
      linkedWorkerLabel: workerLabel,
      linkedWorkerStatusText: statusText,
      isInProgress: message.isInProgress || worker?.status == .running || worker?.status == .pending,
      diffPreview: nil,
      liveOutputPreview: nil,
      toolType: .task,
      outputPreview: reportPreview,
      language: nil,
      mcpServer: nil,
      todoItems: nil
    )
  }

  nonisolated static func linkedWorkerID(for message: TranscriptMessage) -> String? {
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

  private static func workerEventLabel(for message: TranscriptMessage) -> String? {
    let toolName = message.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch toolName {
    case "task":
      return "Assigned task"
    case "wait":
      return message.isInProgress ? "Waiting on worker" : "Worker returned"
    case "handoff":
      return "Handoff"
    case "send_input":
      return "Sent guidance"
    default:
      return toolName.map { CompactToolHelpers.displayName(for: $0) }
    }
  }

  private static func workerEventSummary(for message: TranscriptMessage) -> String? {
    if let taskDescription = trimmed(message.taskDescription) {
      return taskDescription
    }

    if let taskPrompt = trimmed(message.taskPrompt) {
      return taskPrompt
    }

    return trimmed(message.content)
  }

  private static func workerReportPreview(for message: TranscriptMessage) -> String? {
    guard let output = trimmed(message.sanitizedToolOutput) else {
      return nil
    }
    return cleanedWorkerPreview(output)
  }

  private static func workerStatusText(_ status: ServerSubagentStatus?, message: TranscriptMessage) -> String {
    switch status {
    case .pending:
      return "Pending"
    case .running:
      return "Running"
    case .completed:
      return "Complete"
    case .failed:
      return "Failed"
    case .cancelled:
      return "Cancelled"
    case .shutdown:
      return "Stopped"
    case .notFound:
      return "Unavailable"
    case nil:
      return message.isInProgress ? "Running" : "Captured"
    }
  }

  private static func workerGlyphSymbol(for worker: ServerSubagentInfo?) -> String {
    switch worker?.agentType.lowercased() {
    case "explore", "explorer":
      return "binoculars.fill"
    case "plan", "planner":
      return "map.fill"
    case "reviewer":
      return "checklist.checked"
    case "researcher":
      return "magnifyingglass.circle.fill"
    default:
      return "person.2.fill"
    }
  }

  private static func workerGlyphColor(for worker: ServerSubagentInfo?, message: TranscriptMessage) -> PlatformColor {
    switch worker?.status {
    case .completed:
      return PlatformColor(Color.feedbackPositive)
    case .failed, .notFound:
      return PlatformColor(Color.feedbackNegative)
    case .cancelled:
      return PlatformColor(Color.feedbackWarning)
    case .pending:
      return PlatformColor(Color.feedbackCaution)
    case .running:
      return PlatformColor(Color.statusWorking)
    case .shutdown:
      return PlatformColor(Color.textSecondary)
    case nil:
      return PlatformColor(message.isInProgress ? Color.statusWorking : Color.toolTask)
    }
  }

  private static func cleanedWorkerPreview(_ preview: String) -> String {
    if let range = preview.range(of: "Completed(Some(\"") {
      let remainder = preview[range.upperBound...]
      if let closingRange = remainder.range(of: "\"))") {
        return unescapedWorkerPreview(String(remainder[..<closingRange.lowerBound]))
      }
    }

    let filteredLines = preview
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter {
        !$0.isEmpty &&
        !$0.hasPrefix("sender:") &&
        !$0.contains("Completed(Some(")
      }

    if !filteredLines.isEmpty {
      return filteredLines.joined(separator: "\n")
    }

    return unescapedWorkerPreview(preview)
  }

  private static func unescapedWorkerPreview(_ preview: String) -> String {
    preview
      .replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\t", with: "\t")
      .replacingOccurrences(of: "\\\"", with: "\"")
      .trimmingCharacters(in: .whitespacesAndNewlines)
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
    supportsRichToolingCards: Bool,
    subagentsByID: [String: ServerSubagentInfo] = [:]
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
        let workerPresentation = linkedWorkerPresentation(for: message, subagentsByID: subagentsByID)
        let agentType = (message.toolInput?["subagent_type"] as? String) ?? "general"
        let agentLabel = workerPresentation?.label ?? (agentType.isEmpty ? "Agent" : agentType.capitalized)
        let agentColor = ToolGlyphInfo.taskAgentColor(agentType)
        let isComplete = workerPresentation?.statusText == "Complete"
          || (!message.isInProgress && !(message.toolOutput ?? "").isEmpty)
        return .task(
          agentLabel: agentLabel,
          agentColor: agentColor,
          description: workerPresentation?.detailText ?? (message.taskDescription ?? ""),
          output: message.sanitizedToolOutput ?? workerPresentation?.detailText,
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

  nonisolated private static func linkedWorkerPresentation(
    for message: TranscriptMessage,
    subagentsByID: [String: ServerSubagentInfo]
  ) -> WorkerLinkPresentation? {
    guard let linkedWorkerID = linkedWorkerID(for: message),
          let worker = subagentsByID[linkedWorkerID]
    else {
      return nil
    }

    let label = trimmed(worker.label)
      ?? trimmed(worker.taskSummary)
      ?? (worker.agentType.isEmpty ? "Worker" : worker.agentType.capitalized)

    return WorkerLinkPresentation(
      id: linkedWorkerID,
      label: label,
      statusText: statusText(for: worker.status),
      detailText: trimmed(worker.resultSummary) ?? trimmed(worker.taskSummary)
    )
  }

  nonisolated private static func mergeSubtitle(primary: String?, workerSubtitle: String?) -> String? {
    let trimmedPrimary = trimmed(primary)
    let trimmedWorker = trimmed(workerSubtitle)

    switch (trimmedPrimary, trimmedWorker) {
      case let (primary?, worker?) where primary != worker:
        return "\(worker) · \(primary)"
      case let (nil, worker?):
        return worker
      case let (primary?, nil):
        return primary
      default:
        return nil
    }
  }

  nonisolated private static func fallbackWorkerPreview(
    summary: String,
    subtitle: String?,
    existingPreview: String?,
    workerPresentation: WorkerLinkPresentation?
  ) -> String? {
    if let existingPreview = trimmed(existingPreview) {
      return existingPreview
    }

    guard let detailText = trimmed(workerPresentation?.detailText) else {
      return nil
    }

    let blockedValues = [summary, subtitle].compactMap(trimmed)
    return blockedValues.contains(detailText) ? nil : detailText
  }

  nonisolated private static func statusText(for status: ServerSubagentStatus?) -> String {
    switch status {
      case .pending:
        "Pending"
      case .running:
        "Running"
      case .completed:
        "Complete"
      case .failed:
        "Failed"
      case .cancelled:
        "Cancelled"
      case .shutdown:
        "Stopped"
      case .notFound:
        "Unavailable"
      case .none:
        "Worker"
    }
  }

  nonisolated private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
