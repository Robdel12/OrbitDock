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
    switch event {
      case let .turnStarted(e):
        handleTurnStarted(e, sessionId: sessionId)

      case let .turnCompleted(e):
        handleTurnCompleted(e, sessionId: sessionId)

      case let .turnAborted(e):
        handleTurnAborted(e, sessionId: sessionId)

      case let .itemCreated(e):
        handleItemCreated(e, sessionId: sessionId)

      case let .itemUpdated(e):
        handleItemUpdated(e, sessionId: sessionId)

      case let .execApprovalRequest(e):
        handleExecApprovalRequest(e, sessionId: sessionId)

      case let .patchApprovalRequest(e):
        handlePatchApprovalRequest(e, sessionId: sessionId)

      case let .userInputRequest(e):
        handleUserInputRequest(e, sessionId: sessionId)

      case let .elicitationRequest(e):
        handleElicitationRequest(e, sessionId: sessionId)

      case let .sessionConfigured(e):
        handleSessionConfigured(e, sessionId: sessionId)

      case let .threadNameUpdated(e):
        handleThreadNameUpdated(e, sessionId: sessionId)

      case let .error(e):
        handleError(e, sessionId: sessionId)

      case let .unknown(method, _):
        logger.debug("Unhandled event: \(method)")
    }

    // Notify UI to refresh
    notifyTranscriptUpdated()
  }

  // MARK: - Turn Events

  private func handleTurnStarted(_ event: TurnStartedEvent, sessionId: String) {
    logger.debug("Turn started for session: \(sessionId)")

    db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .working,
      attentionReason: .none
    )
  }

  private func handleTurnCompleted(_ event: TurnCompletedEvent, sessionId: String) {
    logger.debug("Turn completed for session: \(sessionId)")

    // Check for error
    if let error = event.error {
      logger.warning("Turn completed with error: \(error.message ?? "unknown")")
    }

    db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .waiting,
      attentionReason: .awaitingReply
    )
  }

  private func handleTurnAborted(_ event: TurnAbortedEvent, sessionId: String) {
    logger.debug("Turn aborted for session: \(sessionId)")

    db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .waiting,
      attentionReason: .awaitingReply
    )
  }

  // MARK: - Item Events

  private func handleItemCreated(_ event: ItemCreatedEvent, sessionId: String) {
    let item = event.item
    logger.debug("Item created: type=\(item.type), id=\(item.id)")

    // Convert item to TranscriptMessage based on type
    // API types: userMessage, agentMessage, reasoning, commandExecution, fileChange, mcpToolCall, etc.
    switch item.type {
      case "userMessage":
        handleUserMessage(item, sessionId: sessionId)

      case "agentMessage":
        handleAgentMessage(item, sessionId: sessionId)

      case "commandExecution":
        handleFunctionCall(item, sessionId: sessionId)

      case "mcpToolCall":
        handleFunctionCall(item, sessionId: sessionId)

      case "fileChange":
        handleFileChange(item, sessionId: sessionId)

      case "reasoning":
        handleReasoning(item, sessionId: sessionId)

      default:
        logger.debug("Unhandled item type: \(item.type)")
    }
  }

  private func handleItemUpdated(_ event: ItemUpdatedEvent, sessionId: String) {
    let item = event.item
    logger.debug("Item updated: type=\(item.type), id=\(item.id)")

    // Handle streaming updates for messages
    switch item.type {
      case "agentMessage":
        handleAgentMessage(item, sessionId: sessionId, isUpdate: true)
      case "reasoning":
        handleReasoning(item, sessionId: sessionId, isUpdate: true)
      default:
        break
    }
  }

  private func handleUserMessage(_ item: ThreadItem, sessionId: String) {
    // Extract text from content blocks
    // UserInput type uses lowercase "text" type
    let text = item.content?.compactMap { block -> String? in
      if block.type == "text" || block.type == "Text" {
        return block.text
      }
      return nil
    }.joined(separator: "\n") ?? ""

    logger.debug("[Codex] UserMessage: content=\(item.content?.count ?? 0) blocks, text='\(text.prefix(50))'")

    guard !text.isEmpty else {
      logger.debug("[Codex] UserMessage skipped: empty text")
      return
    }

    let message = TranscriptMessage(
      id: item.id,
      type: .user,
      content: text,
      timestamp: Date(),
      toolName: nil,
      toolInput: nil,
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )

    messageStore.appendCodexMessage(message, sessionId: sessionId)
    logger.debug("[Codex] UserMessage stored: id=\(item.id)")
  }

  private func handleAgentMessage(_ item: ThreadItem, sessionId: String, isUpdate: Bool = false) {
    // agentMessage has "text" field directly (not content blocks)
    let text = item.text ?? ""

    logger.debug("[Codex] AgentMessage: text='\(text.prefix(50))', isUpdate=\(isUpdate)")

    // On item/started, text may be empty (streaming). Only store if we have content.
    guard !text.isEmpty else {
      logger.debug("[Codex] AgentMessage skipped: empty text")
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

    if isUpdate {
      messageStore.updateCodexMessage(message, sessionId: sessionId)
      logger.debug("[Codex] AgentMessage updated: id=\(item.id)")
    } else {
      messageStore.appendCodexMessage(message, sessionId: sessionId)
      logger.debug("[Codex] AgentMessage stored: id=\(item.id)")
    }
  }

  private func handleFileChange(_ item: ThreadItem, sessionId: String) {
    // File changes show as tool use
    let toolName = "Edit"
    let paths = item.changes?.compactMap { $0.path }.joined(separator: ", ") ?? "files"

    let message = TranscriptMessage(
      id: item.id,
      type: .tool,
      content: "",
      timestamp: Date(),
      toolName: toolName,
      toolInput: ["files": paths],
      toolOutput: nil,
      toolDuration: nil,
      inputTokens: nil,
      outputTokens: nil
    )

    messageStore.appendCodexMessage(message, sessionId: sessionId)
  }

  private func handleFunctionCall(_ item: ThreadItem, sessionId: String) {
    guard let name = item.name else { return }

    // Track start time for duration calculation
    inProgressTools[item.id] = (name: name, startTime: Date())

    // Map Codex tool names to OrbitDock names
    let toolName = mapToolName(name)

    // Update last tool
    db.updateCodexLastTool(sessionId: sessionId, tool: toolName)

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

  private func handleFunctionCallOutput(_ item: ThreadItem, sessionId: String) {
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
    db.incrementCodexToolCount(sessionId: sessionId)

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

  private func handleExecApprovalRequest(_ event: ExecApprovalRequestEvent, sessionId: String) {
    logger.info("Exec approval requested for session: \(sessionId)")

    // Extract command info
    let command = event.command?.command?.joined(separator: " ")
    let inputJson = encodeToolInput(["command": command ?? "unknown", "cwd": event.cwd ?? ""])

    db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: "Shell",
      pendingToolInput: inputJson,
      pendingApprovalId: event.id
    )
  }

  private func handlePatchApprovalRequest(_ event: PatchApprovalRequestEvent, sessionId: String) {
    logger.info("Patch approval requested for session: \(sessionId)")

    let inputJson = encodeToolInput(["path": event.path ?? "unknown", "patch": event.patch ?? ""])

    db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: "Edit",
      pendingToolInput: inputJson,
      pendingApprovalId: event.id
    )
  }

  private func handleUserInputRequest(_ event: UserInputRequestEvent, sessionId: String) {
    logger.info("User input requested for session: \(sessionId)")

    let question = event.questions?.first?.question ?? event.questions?.first?.header

    db.updateCodexDirectSessionStatus(
      sessionId: sessionId,
      workStatus: .waiting,
      attentionReason: .awaitingQuestion,
      pendingQuestion: question,
      pendingApprovalId: event.id
    )
  }

  private func handleElicitationRequest(_ event: ElicitationRequestEvent, sessionId: String) {
    logger.info("Elicitation requested for session: \(sessionId)")

    let question = event.message ?? "MCP server \(event.serverName ?? "unknown") requires input"

    db.updateCodexDirectSessionStatus(
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

  private func handleThreadNameUpdated(_ event: ThreadNameUpdatedEvent, sessionId: String) {
    if let name = event.threadName {
      logger.debug("Thread name updated: \(name)")
      db.updateCustomName(sessionId: sessionId, name: name)
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
