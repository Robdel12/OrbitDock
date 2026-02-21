//
//  SessionObservable.swift
//  OrbitDock
//
//  Per-session @Observable state. Views observe only the session they display,
//  eliminating cascading re-renders when other sessions update.
//

import Foundation

@Observable
@MainActor
final class SessionObservable {
  let id: String

  // Messages
  var messages: [TranscriptMessage] = []
  private(set) var messagesRevision: Int = 0

  // Approval
  var pendingApproval: ServerApprovalRequest?
  var approvalHistory: [ServerApprovalHistoryItem] = []

  // Session metadata
  var tokenUsage: ServerTokenUsage?
  var diff: String?
  var plan: String?
  var autonomy: AutonomyLevel = .autonomous
  var permissionMode: ClaudePermissionMode = .default
  var skills: [ServerSkillMetadata] = []
  var slashCommands: Set<String> = []
  var claudeSkillNames: [String] = []
  var claudeToolNames: [String] = []

  // Turn tracking
  var currentTurnId: String?
  var turnCount: UInt64 = 0
  var turnDiffs: [ServerTurnDiff] = []

  /// Review comments
  var reviewComments: [ServerReviewComment] = []

  // Subagents
  var subagents: [ServerSubagentInfo] = []
  var subagentTools: [String: [ServerSubagentTool]] = [:] // keyed by subagent ID

  /// Shell context buffer — auto-prepended to next sendMessage
  var pendingShellContext: [ShellContextEntry] = []

  // Operation flags
  var undoInProgress: Bool = false
  var forkInProgress: Bool = false
  var forkedFrom: String?

  // MCP state
  var mcpTools: [String: ServerMcpTool] = [:]
  var mcpResources: [String: [ServerMcpResource]] = [:]
  var mcpAuthStatuses: [String: ServerMcpAuthStatus] = [:]
  var mcpStartupState: McpStartupState?

  init(id: String) {
    self.id = id
  }

  func bumpMessagesRevision() {
    messagesRevision += 1
  }

  var hasMcpData: Bool {
    !mcpTools.isEmpty || mcpStartupState != nil
  }

  /// Whether this session supports a given slash command (e.g. "undo", "compact")
  func hasSlashCommand(_ name: String) -> Bool {
    slashCommands.contains(name)
  }

  /// Whether this session has skills available (from Claude init message)
  var hasClaudeSkills: Bool {
    !claudeSkillNames.isEmpty
  }

  /// Parse plan JSON string into PlanStep array for UI
  func getPlanSteps() -> [Session.PlanStep]? {
    guard let json = plan,
          let data = json.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }

    let steps = array.compactMap { dict -> Session.PlanStep? in
      guard let step = dict["step"] as? String else { return nil }
      let status = dict["status"] as? String ?? "pending"
      return Session.PlanStep(step: step, status: status)
    }
    return steps.isEmpty ? nil : steps
  }

  /// Consume pending shell context, wrapping it for AI consumption.
  /// Returns the shell context string to prepend, or nil if none.
  func consumeShellContext() -> String? {
    guard !pendingShellContext.isEmpty else { return nil }
    let entries = pendingShellContext
    pendingShellContext.removeAll()

    let contextBlocks = entries.map { entry in
      var block = "$ \(entry.command)\n\(entry.output)"
      if let code = entry.exitCode {
        block += "\n(exit \(code))"
      }
      return block
    }

    return "<shell-context>\n\(contextBlocks.joined(separator: "\n\n"))\n</shell-context>"
  }

  /// Buffer shell output for injection into next prompt
  func bufferShellContext(command: String, output: String, exitCode: Int32?) {
    pendingShellContext.append(ShellContextEntry(
      command: command,
      output: output,
      exitCode: exitCode,
      timestamp: Date()
    ))
  }

  /// Clear transient state on session end. Keep messages/tokens/history for viewing.
  func clearTransientState() {
    pendingApproval = nil
    undoInProgress = false
    forkInProgress = false
    pendingShellContext = []
    mcpTools = [:]
    mcpResources = [:]
    mcpAuthStatuses = [:]
    mcpStartupState = nil
    skills = []
    slashCommands = []
    claudeSkillNames = []
    claudeToolNames = []
    diff = nil
    plan = nil
    currentTurnId = nil
    permissionMode = .default
  }

  /// Drop heavy conversation payloads when a session is no longer observed.
  /// Keep lightweight identity/config fields so list UI remains stable.
  func clearConversationPayloadsForCaching() {
    messages = []
    bumpMessagesRevision()
    turnDiffs = []
    diff = nil
    plan = nil
    currentTurnId = nil
    pendingShellContext = []
    reviewComments = []
  }
}

// MARK: - Shell Context

struct ShellContextEntry {
  let command: String
  let output: String
  let exitCode: Int32?
  let timestamp: Date
}
