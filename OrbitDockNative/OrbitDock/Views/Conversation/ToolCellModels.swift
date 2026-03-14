//
//  ToolCellModels.swift
//  OrbitDock
//
//  Shared model builders used by both AppKit and UIKit conversation rows.
//

import Foundation
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
    subagentsByID: [String: ServerSubagentInfo] = [:],
    selectedWorkerID: String? = nil
  ) -> NativeCompactToolRowModel {
    guard let display = message.toolDisplay else {
      // Server didn't provide display data — minimal fallback
      let glyph = ToolGlyphInfo.from(message: message)
      let toolName = message.toolName ?? (message.isShell ? "bash" : "tool")
      let workerID = linkedWorkerID(for: message)
      let workerPresentation = linkedWorkerPresentation(for: message, subagentsByID: subagentsByID)
      let workerSubtitle = workerPresentation.map { "\($0.label) · \($0.statusText)" }
      return NativeCompactToolRowModel(
        summary: CompactToolHelpers.displayName(for: toolName),
        subtitle: workerSubtitle,
        rightMeta: message.isInProgress ? "LIVE" : nil,
        glyphSymbol: glyph.symbol,
        glyphColor: glyph.color,
        toolType: .generic,
        language: nil,
        diffPreview: nil,
        outputPreview: workerPresentation?.detailText,
        liveOutputPreview: nil,
        todoItems: nil,
        summaryFont: .system,
        displayTier: .standard,
        timestamp: message.timestamp,
        family: message.toolFamily,
        isInProgress: message.isInProgress,
        mcpServer: CompactToolHelpers.mcpServerName(for: message),
        linkedWorkerID: workerID,
        linkedWorkerLabel: workerPresentation?.label,
        linkedWorkerStatusText: workerPresentation?.statusText,
        isFocusedWorker: workerID != nil && workerID == selectedWorkerID
      )
    }

    return compactToolModelFromServer(
      display: display,
      message: message,
      subagentsByID: subagentsByID,
      selectedWorkerID: selectedWorkerID
    )
  }

  private static func compactToolModelFromServer(
    display: ServerToolDisplay,
    message: TranscriptMessage,
    subagentsByID: [String: ServerSubagentInfo],
    selectedWorkerID: String?
  ) -> NativeCompactToolRowModel {
    let glyphColor = PlatformColor.fromSemanticName(display.glyphColor)
    let toolType = CompactToolHelpers.toolTypeFromString(display.toolType)
    let mcpServer = CompactToolHelpers.mcpServerName(for: message)
    let workerPresentation = linkedWorkerPresentation(for: message, subagentsByID: subagentsByID)

    let diffPreview = display.diffPreview.map { dp in
      DiffPreviewInfo(
        contextLine: dp.contextLine,
        snippetText: dp.snippetText,
        snippetPrefix: dp.snippetPrefix,
        isAddition: dp.isAddition,
        additions: Int(dp.additions),
        deletions: Int(dp.deletions)
      )
    }

    let todoItems: [CompactTodoItem]? = display.todoItems.isEmpty
      ? nil
      : display.todoItems.map { CompactTodoItem(status: NativeTodoStatus($0.status)) }

    var meta = display.rightMeta
    if toolType == .read, let lang = display.language, let existing = meta {
      meta = "\(existing) · \(lang)"
    } else if toolType == .read, let lang = display.language {
      meta = lang
    }

    let workerSubtitle = workerPresentation.map { "\($0.label) · \($0.statusText)" }
    let mergedSubtitle = mergeSubtitle(primary: display.subtitle, workerSubtitle: workerSubtitle)
    let fallbackPreview = fallbackWorkerPreview(
      summary: display.summary,
      subtitle: mergedSubtitle,
      existingPreview: display.outputPreview,
      workerPresentation: workerPresentation
    )

    if display.subtitleAbsorbsMeta, display.subtitle != nil {
      meta = nil
    }

    let fontStyle: SummaryFontStyle = display.summaryFont == "mono" ? .mono : .system
    let tier: DisplayTier = switch display.displayTier {
      case "prominent": .prominent
      case "compact": .compact
      case "minimal": .minimal
      default: .standard
    }

    return NativeCompactToolRowModel(
      summary: display.summary,
      subtitle: mergedSubtitle,
      rightMeta: meta,
      glyphSymbol: display.glyphSymbol,
      glyphColor: glyphColor,
      toolType: toolType,
      language: display.language,
      diffPreview: diffPreview,
      outputPreview: fallbackPreview,
      liveOutputPreview: display.liveOutputPreview,
      todoItems: todoItems,
      summaryFont: fontStyle,
      displayTier: tier,
      timestamp: message.timestamp,
      family: message.toolFamily,
      isInProgress: message.isInProgress,
      mcpServer: mcpServer,
      linkedWorkerID: linkedWorkerID(for: message),
      linkedWorkerLabel: workerPresentation?.label,
      linkedWorkerStatusText: workerPresentation?.statusText,
      isFocusedWorker: linkedWorkerID(for: message) == selectedWorkerID
    )
  }

  static func expandedToolModel(
    from message: TranscriptMessage,
    messageID: String,
    subagentsByID: [String: ServerSubagentInfo] = [:]
  ) -> NativeExpandedToolModel {
    let glyph = ToolGlyphInfo.from(message: message)
    let toolName = message.toolName ?? (message.isShell ? "bash" : "tool")
    let content = expandedToolContent(
      from: message,
      toolName: toolName,
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
      family: message.toolFamily,
      content: content
    )
  }

  static func workerEventModel(
    from message: TranscriptMessage,
    subagentsByID: [String: ServerSubagentInfo] = [:],
    selectedWorkerID: String? = nil
  ) -> NativeCompactToolRowModel? {
    guard let workerID = linkedWorkerID(for: message) else { return nil }

    let worker = subagentsByID[workerID]
    let workerLabel = trimmed(worker?.label)
      ?? trimmed(worker?.agentType)?.capitalized
      ?? "Worker"
    let statusText = workerStatusText(worker?.status, message: message)
    let eventPresentation = workerEventPresentation(for: message, workerLabel: workerLabel)
    let reportPreview = workerReportPreview(for: message)
    let toolType = workerEventToolType(for: message)

    return NativeCompactToolRowModel(
      summary: eventPresentation.summary,
      subtitle: eventPresentation.subtitle,
      rightMeta: statusText,
      glyphSymbol: workerGlyphSymbol(for: worker),
      glyphColor: workerGlyphColor(for: worker, message: message),
      toolType: toolType,
      language: nil,
      diffPreview: nil,
      outputPreview: reportPreview,
      liveOutputPreview: nil,
      todoItems: nil,
      summaryFont: .system,
      displayTier: .standard,
      timestamp: message.timestamp,
      family: message.toolFamily,
      isInProgress: message.isInProgress || worker?.status == .running || worker?.status == .pending,
      mcpServer: nil,
      linkedWorkerID: workerID,
      linkedWorkerLabel: workerLabel,
      linkedWorkerStatusText: statusText,
      isFocusedWorker: workerID == selectedWorkerID
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

  private static func workerEventToolType(for message: TranscriptMessage) -> CompactToolType {
    switch message.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "handoff":
      return .handoff
    case "hook":
      return .hook
    default:
      return .task
    }
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

  private static func workerEventPresentation(
    for message: TranscriptMessage,
    workerLabel: String
  ) -> (summary: String, subtitle: String?) {
    let eventLabel = trimmed(workerEventLabel(for: message))
    let summaryText = trimmed(workerEventSummary(for: message))
    let toolName = message.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    switch toolName {
    case "handoff":
      let summary = message.toolDisplay?.summary ?? "Handoff"
      let detail = summaryText ?? workerReportPreview(for: message)
      let subtitle = trimmed(
        [workerLabel, detail]
          .compactMap(trimmed)
          .joined(separator: " · ")
      )
      return (summary, subtitle)

    case "wait":
      let summary = message.isInProgress ? "Waiting on \(workerLabel)" : "\(workerLabel) reported back"
      return (summary, summaryText)

    case "send_input":
      return ("Guided \(workerLabel)", summaryText ?? eventLabel)

    case "task":
      return (workerLabel, summaryText ?? eventLabel)

    default:
      let subtitle = trimmed(
        [eventLabel, summaryText]
          .compactMap(trimmed)
          .joined(separator: " · ")
      )
      return (workerLabel, subtitle)
    }
  }

  private static func workerEventSummary(for message: TranscriptMessage) -> String? {
    if let taskDescription = trimmed(message.taskDescription) {
      return taskDescription
    }

    if let taskPrompt = trimmed(message.taskPrompt) {
      return taskPrompt
    }

    if let output = trimmed(CompactToolHelpers.compactSanitizedOutputPrefix(for: message, maxChars: 4096)) {
      return compactWorkerSummary(output)
    }

    return trimmed(message.content)
  }

  private static func workerReportPreview(for message: TranscriptMessage) -> String? {
    guard let output = trimmed(CompactToolHelpers.compactSanitizedOutputPrefix(for: message, maxChars: 4096)) else {
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

  private static func compactWorkerSummary(_ value: String) -> String {
    let cleaned = cleanedWorkerPreview(value)
    let firstLine = cleaned
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first(where: { !$0.isEmpty }) ?? cleaned
    if firstLine.count > 120 {
      return String(firstLine.prefix(120)).trimmingCharacters(in: .whitespaces) + "…"
    }
    return firstLine
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
    subagentsByID: [String: ServerSubagentInfo] = [:]
  ) -> NativeToolContent {
    let family = message.toolFamily
    switch family {
      case .shell:
        let command = String.shellCommandDisplay(from: message.content) ?? message.bashCommand ?? message.content
        return .bash(command: command, input: message.fullFormattedToolInput, output: message.sanitizedToolOutput)

      case .file:
        let path = message.filePath
        let filename = path.map { ($0 as NSString).lastPathComponent }
        let normalized = toolName.lowercased()

        if normalized == "read" {
          let language = ToolCardStyle.detectLanguage(from: path)
          let lines = (message.sanitizedToolOutput ?? "").components(separatedBy: "\n")
          return .read(filename: filename, path: path, language: language, lines: lines)
        }

        // edit / write / notebookedit
        let isWriteNew = normalized == "write" && message.editOldString == nil
        let diffLines: [DiffLine]
        if isWriteNew, let content = message.writeContent {
          diffLines = content.components(separatedBy: "\n").enumerated().map { idx, line in
            DiffLine(type: .added, content: line, oldLineNum: nil, newLineNum: idx + 1, prefix: "+")
          }
        } else if let diff = message.unifiedDiff, !diff.isEmpty {
          diffLines = DiffModel.extractChangedLines(fromUnifiedDiff: diff)
        } else {
          diffLines = DiffModel.extractChangedLines(
            oldString: message.editOldString ?? "",
            newString: message.editNewString ?? ""
          )
        }
        let additions = diffLines.filter { $0.type == .added }.count
        let deletions = diffLines.filter { $0.type == .removed }.count
        return .edit(filename: filename, path: path, additions: additions, deletions: deletions, lines: diffLines, isWriteNew: isWriteNew)

      case .search:
        let normalized = toolName.lowercased()
        if normalized == "glob" {
          let pattern = message.globPattern ?? "glob"
          let grouped = Self.groupGlobOutput(message.sanitizedToolOutput)
          return .glob(pattern: pattern, grouped: grouped)
        } else {
          let pattern = message.grepPattern ?? "grep"
          let grouped = Self.groupGrepOutput(message.sanitizedToolOutput)
          return .grep(pattern: pattern, grouped: grouped)
        }

      case .agent:
        let description = message.taskDescription ?? message.taskPrompt ?? message.content
        let workerID = linkedWorkerID(for: message)
        let worker = workerID.flatMap { subagentsByID[$0] }
        let agentLabel = worker?.label ?? worker?.agentType ?? "Agent"
        let agentColor = ToolGlyphInfo.taskAgentColor(worker?.agentType ?? "")
        let isComplete = !message.isInProgress
        return .task(agentLabel: agentLabel, agentColor: agentColor, description: description, output: message.sanitizedToolOutput, isComplete: isComplete)

      case .plan:
        let todoPayload = TodoToolParser.payload(from: message, toolName: toolName, supportsRichToolingCards: true)
        if let payload = todoPayload {
          return .todo(title: payload.title, subtitle: payload.subtitle, items: payload.items, output: payload.output)
        }
        return .generic(toolName: toolName, input: message.fullFormattedToolInput, output: message.sanitizedToolOutput)

      case .mcp:
        let parts = toolName.replacingOccurrences(of: "mcp__", with: "").components(separatedBy: "__")
        let server = parts.first ?? "MCP"
        let displayTool = parts.count > 1 ? parts[1] : toolName
        return .mcp(server: server, displayTool: displayTool, subtitle: nil, input: message.fullFormattedToolInput, output: message.sanitizedToolOutput)

      case .web:
        let normalized = toolName.lowercased()
        if normalized == "websearch" {
          let query = message.toolInput?["query"] as? String ?? message.content
          return .webSearch(query: query, input: message.fullFormattedToolInput, output: message.sanitizedToolOutput)
        } else {
          let url = message.toolInput?["url"] as? String ?? ""
          let domain = URL(string: url)?.host ?? url
          return .webFetch(domain: domain, url: url, input: message.fullFormattedToolInput, output: message.sanitizedToolOutput)
        }

      case .question, .hook, .skill, .generic:
        return .generic(toolName: toolName, input: message.fullFormattedToolInput, output: message.sanitizedToolOutput)
    }
  }

  private static func groupGlobOutput(_ output: String?) -> [(dir: String, files: [String])] {
    guard let output, !output.isEmpty else { return [] }
    let files = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    var grouped: [(dir: String, files: [String])] = []
    var seen: [String: Int] = [:]
    for file in files {
      let components = file.components(separatedBy: "/")
      let dir = components.count > 1 ? components.dropLast().joined(separator: "/") : "."
      if let idx = seen[dir] {
        grouped[idx].files.append(file)
      } else {
        seen[dir] = grouped.count
        grouped.append((dir: dir, files: [file]))
      }
    }
    return grouped
  }

  private static func groupGrepOutput(_ output: String?) -> [(file: String, matches: [String])] {
    guard let output, !output.isEmpty else { return [] }
    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    var grouped: [(file: String, matches: [String])] = []
    var seen: [String: Int] = [:]
    for line in lines {
      let parts = line.split(separator: ":", maxSplits: 1)
      let file = parts.count > 0 ? String(parts[0]) : ""
      let match = parts.count > 1 ? String(parts[1]) : line
      if let idx = seen[file] {
        grouped[idx].matches.append(match)
      } else {
        seen[file] = grouped.count
        grouped.append((file: file, matches: [match]))
      }
    }
    return grouped
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
