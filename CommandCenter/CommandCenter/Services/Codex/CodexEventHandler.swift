//
//  CodexEventHandler.swift
//  OrbitDock
//
//  Transforms Codex app-server events into OrbitDock state updates.
//  Converts events to TranscriptMessage and updates MessageStore.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "CodexEventHandler")
private let fileLogger = CodexFileLogger.shared

@MainActor
final class CodexEventHandler {

  // MARK: - Properties

  private let db: DatabaseManager
  private let messageStore: MessageStore

  /// Track in-progress tool calls for duration calculation
  private var inProgressTools: [String: (name: String, startTime: Date)] = [:]

  // MARK: - Initialization

  nonisolated init(db: DatabaseManager, messageStore: MessageStore) {
    self.db = db
    self.messageStore = messageStore
  }

  // MARK: - Event Handling

  /// Handle an incoming event and update OrbitDock state
  func handle(_ event: CodexServerEvent, sessionId: String) async {
    // Log all events with their type
    let eventType = eventTypeName(event)
    fileLogger.log(.debug, category: .event, message: "Received: \(eventType)", sessionId: sessionId)

    switch event {
      case let .turnStarted(e):
        fileLogger.log(.info, category: .event, message: "turn/started", sessionId: sessionId, data: [
          "threadId": e.threadId ?? "nil",
          "turnId": e.turnId ?? "nil",
        ])
        await handleTurnStarted(e, sessionId: sessionId)

      case let .turnCompleted(e):
        fileLogger.log(.info, category: .event, message: "turn/completed", sessionId: sessionId, data: [
          "threadId": e.threadId ?? "nil",
          "hasError": e.error != nil,
          "errorMessage": e.error?.message ?? "nil",
        ])
        await handleTurnCompleted(e, sessionId: sessionId)

      case let .turnAborted(e):
        fileLogger.log(.info, category: .event, message: "turn/aborted", sessionId: sessionId, data: [
          "threadId": e.threadId ?? "nil",
        ])
        await handleTurnAborted(e, sessionId: sessionId)

      case let .itemCreated(e):
        let item = e.item
        // Log FULL item details for agentMessage to debug missing text
        var itemData: [String: Any] = [
          "itemId": item.id,
          "itemType": item.type,
          "status": item.status ?? "nil",
          "hasContent": item.content != nil,
          "hasText": item.text != nil,
          "textValue": item.text ?? "<nil>",
          "hasCommand": item.command != nil,
          "changesCount": item.changes?.count ?? 0,
        ]
        if item.type == "agentMessage" {
          itemData["textLen"] = item.text?.count ?? 0
          itemData["textPreview"] = String((item.text ?? "").prefix(200))
        }
        fileLogger.log(.info, category: .event, message: "item/created", sessionId: sessionId, data: itemData)
        await handleItemCreated(e, sessionId: sessionId)

      case let .itemUpdated(e):
        let item = e.item
        var updateData: [String: Any] = [
          "itemId": item.id,
          "itemType": item.type,
          "status": item.status ?? "nil",
          "hasOutput": item.aggregatedOutput != nil,
          "outputLen": item.aggregatedOutput?.count ?? 0,
          "changesCount": item.changes?.count ?? 0,
        ]
        // Log text for agentMessage updates
        if item.type == "agentMessage" {
          updateData["hasText"] = item.text != nil
          updateData["textLen"] = item.text?.count ?? 0
          updateData["textPreview"] = String((item.text ?? "").prefix(200))
        }
        fileLogger.log(.debug, category: .event, message: "item/updated", sessionId: sessionId, data: updateData)
        await handleItemUpdated(e, sessionId: sessionId)

      case let .execApprovalRequest(e):
        let command = e.command ?? "unknown"
        fileLogger.log(.warning, category: .event, message: "exec_approval_request", sessionId: sessionId, data: [
          "requestId": e.id,
          "command": String(command.prefix(200)),
          "cwd": e.cwd ?? "nil",
        ])
        await handleExecApprovalRequest(e, sessionId: sessionId)

      case let .patchApprovalRequest(e):
        fileLogger.log(.warning, category: .event, message: "patch_approval_request", sessionId: sessionId, data: [
          "itemId": e.itemId,
          "threadId": e.threadId,
          "turnId": e.turnId,
          "reason": e.reason ?? "nil",
        ])
        await handlePatchApprovalRequest(e, sessionId: sessionId)

      case let .userInputRequest(e):
        fileLogger.log(.warning, category: .event, message: "user_input_request", sessionId: sessionId, data: [
          "requestId": e.id,
          "questionsCount": e.questions?.count ?? 0,
        ])
        await handleUserInputRequest(e, sessionId: sessionId)

      case let .elicitationRequest(e):
        fileLogger.log(.warning, category: .event, message: "elicitation_request", sessionId: sessionId, data: [
          "requestId": e.requestId ?? "nil",
          "serverName": e.serverName ?? "nil",
          "message": e.message ?? "nil",
        ])
        await handleElicitationRequest(e, sessionId: sessionId)

      case let .sessionConfigured(e):
        fileLogger.log(.info, category: .event, message: "session/configured", sessionId: sessionId, data: [
          "model": e.model ?? "nil",
          "cwd": e.cwd ?? "nil",
        ])
        handleSessionConfigured(e, sessionId: sessionId)

      case let .threadNameUpdated(e):
        fileLogger.log(.info, category: .event, message: "thread/name_updated", sessionId: sessionId, data: [
          "threadName": e.threadName ?? "nil",
        ])
        await handleThreadNameUpdated(e, sessionId: sessionId)

      case let .diffUpdated(e):
        fileLogger.log(.info, category: .event, message: "turn/diff/updated", sessionId: sessionId, data: [
          "turnId": e.turnId ?? "nil",
          "diffLen": e.diff?.count ?? 0,
          "diffPreview": String(e.diff?.prefix(100) ?? "nil"),
        ])
        await handleDiffUpdated(e, sessionId: sessionId)

      case let .planUpdated(e):
        fileLogger.log(.info, category: .event, message: "turn/plan/updated", sessionId: sessionId, data: [
          "turnId": e.turnId ?? "nil",
          "stepsCount": e.plan?.count ?? 0,
        ])
        await handlePlanUpdated(e, sessionId: sessionId)

      case let .tokenUsageUpdated(e):
        fileLogger.log(.debug, category: .event, message: "token_usage/updated", sessionId: sessionId, data: [
          "lastInput": e.lastInputTokens ?? -1,
          "lastOutput": e.lastOutputTokens ?? -1,
          "lastCached": e.lastCachedTokens ?? -1,
          "contextWindow": e.contextWindow ?? -1,
        ])
        await handleTokenUsageUpdated(e, sessionId: sessionId)

      case let .rateLimitsUpdated(e):
        fileLogger.log(.debug, category: .event, message: "rate_limits/updated", sessionId: sessionId, data: [
          "primaryUsed": e.rateLimits?.primary?.usedPercent ?? -1,
          "secondaryUsed": e.rateLimits?.secondary?.usedPercent ?? -1,
        ])
        handleRateLimitsUpdated(e, sessionId: sessionId)

      case let .mcpStartupUpdate(e):
        fileLogger.log(.debug, category: .event, message: "mcp/startup_update", sessionId: sessionId, data: [
          "server": e.server ?? "nil",
          "state": e.status?.state ?? "nil",
        ])
        handleMCPStartupUpdate(e, sessionId: sessionId)

      case let .mcpStartupComplete(e):
        fileLogger.log(.info, category: .event, message: "mcp/startup_complete", sessionId: sessionId, data: [
          "server": e.server ?? "nil",
        ])
        handleMCPStartupComplete(e, sessionId: sessionId)

      case let .error(e):
        fileLogger.log(.error, category: .event, message: "error", sessionId: sessionId, data: [
          "code": e.code ?? "nil",
          "errorMessage": e.message ?? "nil",
        ])
        handleError(e, sessionId: sessionId)

      case .ignored:
        // Silently drop streaming deltas and legacy duplicates
        return

      case let .unknown(method, payload):
        let keys: [String] = (payload?.dictionary?.keys).map { Array($0) } ?? []
        fileLogger.log(.warning, category: .event, message: "unknown_event", sessionId: sessionId, data: [
          "method": method,
          "payloadKeys": keys,
        ])
        logger.debug("Unhandled event: \(method)")
    }

    // Notify UI to refresh
    notifyTranscriptUpdated()
  }

  /// Get a readable name for an event type
  private func eventTypeName(_ event: CodexServerEvent) -> String {
    switch event {
      case .turnStarted: return "turn/started"
      case .turnCompleted: return "turn/completed"
      case .turnAborted: return "turn/aborted"
      case .itemCreated: return "item/created"
      case .itemUpdated: return "item/updated"
      case .execApprovalRequest: return "exec_approval_request"
      case .patchApprovalRequest: return "patch_approval_request"
      case .userInputRequest: return "user_input_request"
      case .elicitationRequest: return "elicitation_request"
      case .sessionConfigured: return "session/configured"
      case .threadNameUpdated: return "thread/name_updated"
      case .diffUpdated: return "turn/diff/updated"
      case .planUpdated: return "turn/plan/updated"
      case .tokenUsageUpdated: return "token_usage/updated"
      case .rateLimitsUpdated: return "rate_limits/updated"
      case .mcpStartupUpdate: return "mcp/startup_update"
      case .mcpStartupComplete: return "mcp/startup_complete"
      case .error: return "error"
      case .ignored: return "ignored"
      case let .unknown(method, _): return "unknown:\(method)"
    }
  }

  // MARK: - Turn Events

  private func handleTurnStarted(_ event: TurnStartedEvent, sessionId: String) async {
    logger.debug("Turn started for session: \(sessionId)")

    await db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .working,
      attentionReason: .none
    )
  }

  private func handleTurnCompleted(_ event: TurnCompletedEvent, sessionId: String) async {
    logger.debug("Turn completed for session: \(sessionId)")

    // Check for error
    if let error = event.error {
      logger.warning("Turn completed with error: \(error.message ?? "unknown")")
    }

    await db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .waiting,
      attentionReason: .awaitingReply
    )
  }

  private func handleTurnAborted(_ event: TurnAbortedEvent, sessionId: String) async {
    logger.debug("Turn aborted for session: \(sessionId)")

    await db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .waiting,
      attentionReason: .awaitingReply
    )
  }

  // MARK: - Item Events

  private func handleItemCreated(_ event: ItemCreatedEvent, sessionId: String) async {
    let item = event.item
    logger.info("Item created: type=\(item.type), id=\(item.id), status=\(item.status ?? "nil")")

    // Convert item to TranscriptMessage based on type
    // API types: userMessage, agentMessage, reasoning, commandExecution, fileChange, mcpToolCall, etc.
    switch item.type {
      case "userMessage":
        handleUserMessage(item, sessionId: sessionId)

      case "agentMessage":
        handleAgentMessage(item, sessionId: sessionId)

      case "commandExecution":
        await handleCommandExecution(item, sessionId: sessionId)

      case "mcpToolCall":
        await handleFunctionCall(item, sessionId: sessionId)

      case "fileChange":
        handleFileChange(item, sessionId: sessionId)

      case "reasoning":
        handleReasoning(item, sessionId: sessionId)

      case "webSearch":
        handleWebSearch(item, sessionId: sessionId)

      default:
        logger.debug("Unhandled item type: \(item.type)")
    }
  }

  private func handleItemUpdated(_ event: ItemUpdatedEvent, sessionId: String) async {
    let item = event.item
    logger.debug("Item updated: type=\(item.type), id=\(item.id)")

    // Handle streaming updates and completions
    switch item.type {
      case "agentMessage":
        handleAgentMessage(item, sessionId: sessionId, isUpdate: true)
      case "reasoning":
        handleReasoning(item, sessionId: sessionId, isUpdate: true)
      case "webSearch":
        handleWebSearch(item, sessionId: sessionId, isUpdate: true)
      case "commandExecution":
        await handleCommandExecutionUpdate(item, sessionId: sessionId)
      case "fileChange":
        // item/completed has the final diff data
        await handleFileChangeUpdate(item, sessionId: sessionId)
      default:
        break
    }
  }

  private func handleCommandExecutionUpdate(_ item: ThreadItem, sessionId: String) async {
    // Update shell command with output when complete
    let command = item.command ?? "shell"

    var toolInput: [String: Any] = ["command": command]
    if let cwd = item.cwd {
      toolInput["cwd"] = cwd
    }

    // Calculate duration if we tracked this
    var duration: TimeInterval?
    if let startInfo = inProgressTools.removeValue(forKey: item.id) {
      duration = Date().timeIntervalSince(startInfo.startTime)
    }

    var message = TranscriptMessage(
      id: item.id,
      type: .tool,
      content: "",
      timestamp: Date(),
      toolName: "Bash",
      toolInput: toolInput,
      toolOutput: item.aggregatedOutput,
      toolDuration: duration,
      inputTokens: nil,
      outputTokens: nil
    )
    message.isInProgress = false

    messageStore.updateCodexMessage(message, sessionId: sessionId)

    // Increment tool count if we have output (command finished)
    if item.aggregatedOutput != nil {
      await db.incrementCodexToolCount(sessionId: sessionId)
    }

    logger.debug("Command execution updated: \(command.prefix(50)), output: \(item.aggregatedOutput?.count ?? 0) chars")
  }

  private func handleUserMessage(_ item: ThreadItem, sessionId: String) {
    // Skip storing - user messages are already stored when sent via CodexInputBar.
    // The server's userMessage event is just a confirmation with a different ID.
    let text = item.content?.compactMap { block -> String? in
      if block.type == "text" || block.type == "Text" {
        return block.text
      }
      return nil
    }.joined(separator: "\n") ?? ""

    logger.debug("[Codex] UserMessage: content=\(item.content?.count ?? 0) blocks, text='\(text.prefix(50))'")
    // Don't store - already stored locally when user sent the message
  }

  private func handleAgentMessage(_ item: ThreadItem, sessionId: String, isUpdate: Bool = false) {
    // agentMessage has "text" field directly (not content blocks)
    let text = item.text ?? ""

    fileLogger.log(.debug, category: .message, message: "agentMessage handler", sessionId: sessionId, data: [
      "itemId": item.id,
      "isUpdate": isUpdate,
      "textLen": text.count,
      "textPreview": String(text.prefix(100)),
      "hasText": item.text != nil,
    ])

    // On item/started, text may be empty (streaming). Only store if we have content.
    guard !text.isEmpty else {
      fileLogger.log(.debug, category: .message, message: "agentMessage skipped: empty text", sessionId: sessionId, data: [
        "itemId": item.id,
        "isUpdate": isUpdate,
      ])
      return
    }

    let message = TranscriptMessage(
      id: item.id,
      type: .assistant,
      content: text,
      timestamp: Date(),
      toolName: nil,
      toolInput: nil,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )

    // Always use upsert - text often arrives in item/updated after item/created was skipped
    // because text was empty during streaming
    messageStore.upsertCodexMessage(message, sessionId: sessionId)
    fileLogger.log(.info, category: .message, message: "agentMessage upserted", sessionId: sessionId, data: [
      "itemId": item.id,
      "textLen": text.count,
      "wasUpdate": isUpdate,
    ])
  }

  private func handleCommandExecution(_ item: ThreadItem, sessionId: String) async {
    // Shell command execution with output
    let command = item.command ?? "shell"

    // Track for duration
    inProgressTools[item.id] = (name: "Shell", startTime: Date())

    // Update last tool
    await db.updateCodexLastTool(sessionId: sessionId, tool: "Shell")

    // Build tool input for BashCard display
    var toolInput: [String: Any] = ["command": command]
    if let cwd = item.cwd {
      toolInput["cwd"] = cwd
    }

    var message = TranscriptMessage(
      id: item.id,
      type: .tool,
      content: command,  // BashCard displays content as the command
      timestamp: Date(),
      toolName: "Bash",
      toolInput: toolInput,
      toolOutput: item.aggregatedOutput,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )

    // Check if command is complete (has output or exit code)
    if item.aggregatedOutput != nil || item.exitCode != nil {
      message.isInProgress = false
      if let startInfo = inProgressTools.removeValue(forKey: item.id) {
        message = TranscriptMessage(
          id: item.id,
          type: .tool,
          content: "",
          timestamp: Date(),
          toolName: "Bash",
          toolInput: toolInput,
          toolOutput: item.aggregatedOutput,
          toolDuration: Date().timeIntervalSince(startInfo.startTime),
          inputTokens: nil,
          outputTokens: nil
        )
      }
      await db.incrementCodexToolCount(sessionId: sessionId)
    } else {
      message.isInProgress = true
    }

    messageStore.appendCodexMessage(message, sessionId: sessionId)
    logger.debug("Command execution: \(command.prefix(50))")
  }

  private func handleFileChange(_ item: ThreadItem, sessionId: String) {
    // item/started: Create placeholder messages for file changes
    // The actual diff data comes in item/completed
    let changesCount = item.changes?.count ?? 0
    logger.info("FileChange item: changes=\(changesCount), status=\(item.status ?? "nil")")

    // Log each change's details
    if let changes = item.changes {
      let changesData = changes.enumerated().map { i, change -> [String: Any] in
        [
          "index": i,
          "path": change.path ?? "nil",
          "kind": change.kind?.type ?? "nil",
          "hasDiff": change.diff != nil && !(change.diff?.isEmpty ?? true),
          "diffLen": change.diff?.count ?? 0,
        ]
      }
      fileLogger.log(.info, category: .event, message: "fileChange/started", sessionId: sessionId, data: [
        "itemId": item.id,
        "changesCount": changesCount,
        "status": item.status ?? "nil",
        "changes": changesData,
      ])
    }

    guard let changes = item.changes, !changes.isEmpty else {
      logger.warning("FileChange has no changes array")
      fileLogger.log(.warning, category: .event, message: "fileChange/started: NO CHANGES", sessionId: sessionId, data: ["itemId": item.id])
      return
    }

    // Track start time for duration
    inProgressTools[item.id] = (name: "Edit", startTime: Date())

    // Process each file change
    for change in changes {
      guard let path = change.path else { continue }

      var toolInput: [String: Any] = ["file_path": path]

      // If diff is already available (sometimes it is), include it
      if let diff = change.diff, !diff.isEmpty {
        toolInput["unified_diff"] = diff
        let (oldString, newString) = parseUnifiedDiff(diff)
        if !oldString.isEmpty { toolInput["old_string"] = oldString }
        if !newString.isEmpty { toolInput["new_string"] = newString }
      }

      var message = TranscriptMessage(
        id: "\(item.id)-\(path)",
        type: .tool,
        content: "",
        timestamp: Date(),
        toolName: "Edit",
        toolInput: toolInput,
        toolOutput: nil,
        toolDuration: nil,
        inputTokens: nil,
        outputTokens: nil
      )
      message.isInProgress = (item.status == "inProgress" || item.status == nil)

      messageStore.appendCodexMessage(message, sessionId: sessionId)
      logger.debug("File change started: \(path)")
    }
  }

  private func handleFileChangeUpdate(_ item: ThreadItem, sessionId: String) async {
    // item/completed: Update with final diff data
    let changesCount = item.changes?.count ?? 0
    logger.info("FileChange UPDATE: changes=\(changesCount), status=\(item.status ?? "nil")")

    // Log each change's details
    if let changes = item.changes {
      let changesData = changes.enumerated().map { i, change -> [String: Any] in
        var changeInfo: [String: Any] = [
          "index": i,
          "path": change.path ?? "nil",
          "kind": change.kind?.type ?? "nil",
          "hasDiff": change.diff != nil && !(change.diff?.isEmpty ?? true),
          "diffLen": change.diff?.count ?? 0,
        ]
        if let diff = change.diff, !diff.isEmpty {
          changeInfo["diffPreview"] = String(diff.prefix(200))
        }
        return changeInfo
      }
      fileLogger.log(.info, category: .event, message: "fileChange/completed", sessionId: sessionId, data: [
        "itemId": item.id,
        "changesCount": changesCount,
        "status": item.status ?? "nil",
        "changes": changesData,
      ])
    }

    guard let changes = item.changes, !changes.isEmpty else {
      logger.warning("FileChange update has no changes array")
      fileLogger.log(.warning, category: .event, message: "fileChange/completed: NO CHANGES", sessionId: sessionId, data: ["itemId": item.id])
      return
    }

    // Calculate duration
    var duration: TimeInterval?
    if let startInfo = inProgressTools.removeValue(forKey: item.id) {
      duration = Date().timeIntervalSince(startInfo.startTime)
    }

    for change in changes {
      guard let path = change.path else { continue }

      var toolInput: [String: Any] = ["file_path": path]

      // Now we should have the diff data
      if let diff = change.diff, !diff.isEmpty {
        toolInput["unified_diff"] = diff
        let (oldString, newString) = parseUnifiedDiff(diff)
        if !oldString.isEmpty { toolInput["old_string"] = oldString }
        if !newString.isEmpty { toolInput["new_string"] = newString }
        logger.debug("File change completed with diff: \(path), \(diff.count) chars")
      } else {
        logger.debug("File change completed without diff: \(path)")
      }

      var message = TranscriptMessage(
        id: "\(item.id)-\(path)",
        type: .tool,
        content: "",
        timestamp: Date(),
        toolName: "Edit",
        toolInput: toolInput,
        toolOutput: nil,
        toolDuration: duration,
        inputTokens: nil,
        outputTokens: nil
      )
      message.isInProgress = false

      messageStore.updateCodexMessage(message, sessionId: sessionId)
    }

    // Increment tool count
    await db.incrementCodexToolCount(sessionId: sessionId)
  }

  /// Parse unified diff format into old and new strings for EditCard display
  private func parseUnifiedDiff(_ diff: String) -> (old: String, new: String) {
    var oldLines: [String] = []
    var newLines: [String] = []

    for line in diff.components(separatedBy: "\n") {
      // Skip headers and hunk markers
      if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("@@") || line.hasPrefix("diff ") {
        continue
      }

      if line.hasPrefix("-") {
        // Removed line (goes to old)
        oldLines.append(String(line.dropFirst()))
      } else if line.hasPrefix("+") {
        // Added line (goes to new)
        newLines.append(String(line.dropFirst()))
      } else if line.hasPrefix(" ") {
        // Context line (goes to both)
        let content = String(line.dropFirst())
        oldLines.append(content)
        newLines.append(content)
      } else if !line.isEmpty {
        // Other lines (context without prefix)
        oldLines.append(line)
        newLines.append(line)
      }
    }

    return (oldLines.joined(separator: "\n"), newLines.joined(separator: "\n"))
  }

  private func handleWebSearch(_ item: ThreadItem, sessionId: String, isUpdate: Bool = false) {
    // Web search shows as tool use
    let message = TranscriptMessage(
      id: item.id,
      type: .tool,
      content: "",
      timestamp: Date(),
      toolName: "WebSearch",
      toolInput: ["query": item.query ?? "search"],
      toolOutput: item.searchResults,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )

    if isUpdate {
      messageStore.updateCodexMessage(message, sessionId: sessionId)
    } else {
      messageStore.appendCodexMessage(message, sessionId: sessionId)
    }
  }

  private func handleFunctionCall(_ item: ThreadItem, sessionId: String) async {
    guard let name = item.name else { return }

    // Track start time for duration calculation
    inProgressTools[item.id] = (name: name, startTime: Date())

    // Map Codex tool names to OrbitDock names
    let toolName = mapToolName(name)

    // Update last tool
    await db.updateCodexLastTool(sessionId: sessionId, tool: toolName)

    // Parse arguments for display
    let toolInputDict = item.arguments?.dictionary as? [String: Any]

    var message = TranscriptMessage(
      id: item.id,
      type: .tool,
      content: "",
      timestamp: Date(),
      toolName: toolName,
      toolInput: toolInputDict,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )
    message.isInProgress = true

    messageStore.appendCodexMessage(message, sessionId: sessionId)

    logger.debug("Tool call started: \(toolName)")
  }

  private func handleFunctionCallOutput(_ item: ThreadItem, sessionId: String) async {
    guard let callId = item.callId else { return }

    // Calculate duration
    var duration: TimeInterval?
    let toolNameFromTracking = inProgressTools[callId]?.name
    if let startInfo = inProgressTools.removeValue(forKey: callId) {
      duration = Date().timeIntervalSince(startInfo.startTime)
    }

    // Update the tool message with output
    var message = TranscriptMessage(
      id: callId,
      type: .tool,
      content: "",
      timestamp: Date(),
      toolName: toolNameFromTracking.map { mapToolName($0) },
      toolInput: nil,
      toolOutput: item.output,
      toolDuration: duration,
      inputTokens: nil,
      outputTokens: nil
    )
    message.isInProgress = false

    messageStore.updateCodexMessage(message, sessionId: sessionId)

    // Increment tool count
    await db.incrementCodexToolCount(sessionId: sessionId)

    logger.debug("Tool call completed: \(callId)")
  }

  private func handleReasoning(_ item: ThreadItem, sessionId: String, isUpdate: Bool = false) {
    guard let summaryText = item.summaryText, !summaryText.isEmpty else { return }

    let content = summaryText.joined(separator: "\n")

    var message = TranscriptMessage(
      id: item.id,
      type: .thinking,
      content: content,
      timestamp: Date(),
      toolName: nil,
      toolInput: nil,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )
    message.thinking = content

    if isUpdate {
      messageStore.updateCodexMessage(message, sessionId: sessionId)
    } else {
      messageStore.appendCodexMessage(message, sessionId: sessionId)
    }
  }

  // MARK: - Approval Events

  private func handleExecApprovalRequest(_ event: ExecApprovalRequestEvent, sessionId: String) async {
    logger.info("Exec approval requested for session: \(sessionId)")

    // Extract command info
    let command = event.command
    let inputJson = encodeToolInput(["command": command ?? "unknown", "cwd": event.cwd ?? ""])

    await db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: "Shell",
      pendingToolInput: inputJson,
      pendingApprovalId: event.id
    )
  }

  private func handlePatchApprovalRequest(_ event: PatchApprovalRequestEvent, sessionId: String) async {
    logger.info("Patch approval requested for session: \(sessionId), itemId: \(event.itemId)")

    // The new API uses itemId to reference the fileChange item
    // The actual path/diff is in the fileChange item that was already created
    let inputJson = encodeToolInput([
      "itemId": event.itemId,
      "reason": event.reason ?? ""
    ])

    await db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: "Edit",
      pendingToolInput: inputJson,
      pendingApprovalId: event.itemId
    )
  }

  private func handleUserInputRequest(_ event: UserInputRequestEvent, sessionId: String) async {
    logger.info("User input requested for session: \(sessionId)")

    let question = event.questions?.first?.question ?? event.questions?.first?.header

    await db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .waiting,
      attentionReason: .awaitingQuestion,
      pendingQuestion: question,
      pendingApprovalId: event.id
    )
  }

  private func handleElicitationRequest(_ event: ElicitationRequestEvent, sessionId: String) async {
    logger.info("Elicitation requested for session: \(sessionId)")

    let question = event.message ?? "MCP server \(event.serverName ?? "unknown") requires input"

    await db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .waiting,
      attentionReason: .awaitingQuestion,
      pendingQuestion: question,
      pendingApprovalId: event.requestId
    )
  }

  // MARK: - Session Events

  private func handleSessionConfigured(_ event: SessionConfiguredEvent, sessionId: String) {
    logger.debug("Session configured: model=\(event.model ?? "nil"), cwd=\(event.cwd ?? "nil")")
    // Could update session model/cwd if different
  }

  private func handleThreadNameUpdated(_ event: ThreadNameUpdatedEvent, sessionId: String) async {
    if let name = event.threadName {
      logger.debug("Thread name updated: \(name)")
      await db.updateCustomName(sessionId: sessionId, name: name)
    }
  }

  // MARK: - Error Events

  private func handleError(_ event: CodexErrorEvent, sessionId: String) {
    logger.error("Codex error: \(event.code ?? "unknown") - \(event.message ?? "no message")")

    // Add error message to transcript
    let message = TranscriptMessage(
      id: UUID().uuidString,
      type: .system,
      content: "Error: \(event.message ?? "Unknown error")",
      timestamp: Date(),
      toolName: nil,
      toolInput: nil,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )

    messageStore.appendCodexMessage(message, sessionId: sessionId)
  }

  // MARK: - Usage Events

  private func handleTokenUsageUpdated(_ event: TokenUsageEvent, sessionId: String) async {
    // Use LAST turn tokens for context fill (what's actually in the context window)
    // Total is cumulative across the session and can exceed the window due to compaction
    let inputTokens = event.lastInputTokens
    let outputTokens = event.lastOutputTokens
    let cachedTokens = event.lastCachedTokens  // Cache for this turn
    let contextWindow = event.contextWindow

    // Detailed logging to understand token data
    logger.info("""
      [TokenUsage] session=\(sessionId)
        last.input=\(inputTokens ?? -1) (context fill)
        last.output=\(outputTokens ?? -1)
        last.cached=\(cachedTokens ?? -1)
        contextWindow=\(contextWindow ?? -1)
      """)

    // Update session with token counts for display
    await db.updateCodexTokenUsage(
      sessionId: sessionId,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens,
      contextWindow: contextWindow
    )
  }

  private func handleRateLimitsUpdated(_ event: RateLimitsEvent, sessionId: String) {
    guard let limits = event.rateLimits else { return }

    let primaryPercent = limits.primary?.usedPercent ?? 0
    let secondaryPercent = limits.secondary?.usedPercent ?? 0
    logger.debug("Rate limits updated: primary=\(primaryPercent)%, secondary=\(secondaryPercent)%")

    // Could update usage display here - for now just log
    // The CodexUsageService already fetches this periodically
  }

  // MARK: - Diff & Plan Events

  private func handleDiffUpdated(_ event: DiffUpdatedEvent, sessionId: String) async {
    guard let diff = event.diff, !diff.isEmpty else { return }

    logger.debug("Diff updated for session \(sessionId): \(diff.count) chars")

    // Store in memory for fast UI updates
    CodexTurnStateStore.shared.updateDiff(sessionId: sessionId, diff: diff)

    // Persist to database for app restart
    await db.updateCodexDiff(sessionId: sessionId, diff: diff)

    // Create/update a synthetic Edit message for inline display
    // Parse files from the unified diff
    let files = parseFilesFromDiff(diff)
    let turnId = event.turnId ?? "turn-diff"

    // Create a single Edit message with all changes
    let (oldString, newString) = parseUnifiedDiff(diff)
    var toolInput: [String: Any] = [
      "unified_diff": diff,
      "files": files.joined(separator: ", ")
    ]
    if !oldString.isEmpty { toolInput["old_string"] = oldString }
    if !newString.isEmpty { toolInput["new_string"] = newString }

    // Use first file as the path for EditCard display
    if let firstFile = files.first {
      toolInput["file_path"] = firstFile
    }

    let message = TranscriptMessage(
      id: "diff-\(turnId)",
      type: .tool,
      content: "",
      timestamp: Date(),
      toolName: "Edit",
      toolInput: toolInput,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )

    // Log before upsert
    fileLogger.log(.debug, category: .message, message: "diff/upsert", sessionId: sessionId, data: [
      "messageId": "diff-\(turnId)",
      "files": files,
      "diffLen": diff.count,
      "oldStringLen": oldString.count,
      "newStringLen": newString.count,
    ])

    // Upsert - insert if new, update if exists (diff may update multiple times per turn)
    messageStore.upsertCodexMessage(message, sessionId: sessionId)
  }

  /// Extract file paths from unified diff
  private func parseFilesFromDiff(_ diff: String) -> [String] {
    var files: [String] = []
    for line in diff.components(separatedBy: "\n") {
      // Match: +++ b/path/to/file
      if line.hasPrefix("+++ b/") {
        let path = String(line.dropFirst(6))
        files.append(path)
      }
      // Also match: +++ path/to/file (without b/ prefix)
      else if line.hasPrefix("+++ "), !line.hasPrefix("+++ /dev/null") {
        let path = String(line.dropFirst(4))
        files.append(path)
      }
    }
    return files
  }

  private func handlePlanUpdated(_ event: PlanUpdatedEvent, sessionId: String) async {
    guard let steps = event.plan, !steps.isEmpty else { return }

    logger.debug("Plan updated for session \(sessionId): \(steps.count) steps")

    // Convert protocol PlanStep to Session.PlanStep
    let sessionSteps = steps.map { Session.PlanStep(step: $0.step, status: $0.status) }

    // Store in memory for fast UI updates
    CodexTurnStateStore.shared.updatePlan(sessionId: sessionId, plan: sessionSteps)

    // Persist to database for app restart
    await db.updateCodexPlan(sessionId: sessionId, plan: sessionSteps)
  }

  // MARK: - MCP Events

  private func handleMCPStartupUpdate(_ event: MCPStartupEvent, sessionId: String) {
    let server = event.server ?? "unknown"
    let state = event.status?.state ?? "unknown"

    logger.debug("MCP startup update: \(server) - \(state)")

    // Could show MCP connection status in UI
    // For now just log - MCP servers typically start quickly
  }

  private func handleMCPStartupComplete(_ event: MCPStartupEvent, sessionId: String) {
    let server = event.server ?? "unknown"

    logger.debug("MCP startup complete: \(server)")

    // MCP server is ready - no action needed
  }

  // MARK: - Helpers

  /// Map Codex tool names to OrbitDock display names
  private func mapToolName(_ codexName: String) -> String {
    switch codexName {
      case "exec_command", "shell": return "Shell"
      case "apply_patch", "patch_apply": return "Edit"
      case "read_file": return "Read"
      case "write_file": return "Write"
      case "list_directory": return "Glob"
      case "search_files": return "Grep"
      case "web_search": return "WebSearch"
      case "view_image": return "ViewImage"
      default: return codexName
    }
  }

  /// Parse tool input JSON string into dictionary
  private func parseToolInput(_ json: String?) -> [String: Any]? {
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  /// Encode tool input dictionary to JSON string
  private func encodeToolInput(_ dict: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Notify UI of transcript changes
  private func notifyTranscriptUpdated() {
    EventBus.shared.notifyDatabaseChanged()
  }
}
