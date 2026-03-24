//
//  SessionObservable.swift
//  OrbitDock
//
//  Per-session @Observable state for session data and conversation timeline.
//

import Foundation

struct McpStartupState {
  var serverStatuses: [String: ServerMcpStartupStatus] = [:]
  var isComplete = false
  var readyServers: [String] = []
  var failedServers: [ServerMcpStartupFailure] = []
  var cancelledServers: [String] = []
}

@Observable
@MainActor
final class SessionObservable {
  let id: String

  // Approval
  var pendingApproval: ServerApprovalRequest?
  var approvalHistory: [ServerApprovalHistoryItem] = []
  var approvalVersion: UInt64 = 0

  // Session metadata
  var tokenUsage: ServerTokenUsage?
  var tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind = .unknown
  var diff: String?
  var cumulativeDiff: String?
  var plan: String?
  var autonomy: AutonomyLevel = .autonomous
  var autonomyConfiguredOnServer: Bool = true
  var permissionMode: ClaudePermissionMode = .default
  var allowBypassPermissions: Bool = false
  var collaborationMode: String?
  var multiAgent: Bool?
  var personality: String?
  var serviceTier: String?
  var developerInstructions: String?
  var codexConfigSource: ServerCodexConfigSource?
  var codexConfigMode: ServerCodexConfigMode?
  var codexConfigProfile: String?
  var codexModelProvider: String?
  var codexConfigOverrides: ServerCodexSessionOverrides?
  var permissionRules: ServerSessionPermissionRules?
  var permissionRulesLoading: Bool = false
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
  var subagentMessages: [String: [ServerConversationRowEntry]] = [:] // keyed by subagent ID

  /// Shell context buffer — auto-prepended to next sendMessage
  var pendingShellContext: [ShellContextEntry] = []

  // Conversation
  private(set) var rowEntries: [ServerConversationRowEntry] = []
  private(set) var rowEntriesRevision: Int = 0
  private(set) var rowEntriesStructureRevision: Int = 0
  private(set) var rowEntriesContentRevision: Int = 0
  private(set) var lastChangedRowEntries: [ServerConversationRowEntry] = []
  private(set) var lastRemovedRowIds: [String] = []
  private(set) var hasMoreHistoryBefore: Bool = false
  var isLoadingOlderMessages: Bool = false
  var conversationLoaded: Bool = false
  @ObservationIgnored var oldestLoadedSequence: UInt64?

  // Operation flags
  var undoInProgress: Bool = false
  var compactInProgress: Bool = false
  var rollbackInProgress: Bool = false
  var forkInProgress: Bool = false
  var forkedFrom: String?

  // MCP state
  var mcpTools: [String: ServerMcpTool] = [:]
  var mcpResources: [String: [ServerMcpResource]] = [:]
  var mcpResourceTemplates: [String: [ServerMcpResourceTemplate]] = [:]
  var mcpAuthStatuses: [String: ServerMcpAuthStatus] = [:]
  var mcpStartupState: McpStartupState?

  /// Rate limit
  var rateLimitInfo: ServerRateLimitInfo?

  /// Prompt suggestions (cleared on TurnStarted)
  var promptSuggestions: [String] = []

  // MARK: - Session-level fields (mirrored from Session struct for detail views)

  var endpointId: UUID?
  var endpointName: String?
  var endpointConnectionStatus: ConnectionStatus?
  var projectPath: String = ""
  var projectName: String?
  var branch: String?
  var model: String?
  var effort: String?
  var summary: String?
  var customName: String?
  var firstPrompt: String?
  var lastMessage: String?
  var transcriptPath: String?
  var status: Session.SessionStatus = .active
  var workStatus: Session.WorkStatus = .unknown
  var steerable: Bool = false
  var attentionReason: Session.AttentionReason = .none
  var lastActivityAt: Date?
  var lastFilesPersistedAt: Date?
  var lastTool: String?
  var lastToolAt: Date?
  var inputTokens: Int?
  var outputTokens: Int?
  var cachedTokens: Int?
  var contextWindow: Int?
  var totalTokens: Int = 0
  var totalCostUSD: Double = 0
  var provider: Provider = .claude
  var codexIntegrationMode: CodexIntegrationMode?
  var claudeIntegrationMode: ClaudeIntegrationMode?
  var codexThreadId: String?
  var pendingApprovalId: String?
  var pendingToolName: String?
  var pendingToolInput: String?
  var pendingPermissionDetail: String?
  var pendingQuestion: String?
  var promptCount: Int = 0
  var toolCount: Int = 0
  var startedAt: Date?
  var endedAt: Date?
  var endReason: String?
  var gitSha: String?
  var currentCwd: String?
  var repositoryRoot: String?
  var isWorktree: Bool = false
  var worktreeId: String?
  var unreadCount: UInt64 = 0
  var missionId: String?
  var issueIdentifier: String?

  init(id: String) {
    self.id = id
  }

  // MARK: - Computed properties (mirror Session computed logic)

  var isActive: Bool {
    status == .active
  }

  var displayStatus: SessionDisplayStatus {
    guard isActive else { return .ended }
    switch attentionReason {
      case .awaitingPermission: return .permission
      case .awaitingQuestion: return .question
      case .awaitingReply: return .reply
      case .none:
        switch workStatus {
          case .working:
            return .working
          case .permission:
            return .permission
          case .question:
            return .question
          case .waiting, .reply, .unknown:
            return .reply
          case .ended:
            return .ended
        }
    }
  }

  var isDirect: Bool {
    isDirectCodex || isDirectClaude
  }

  var isDirectCodex: Bool {
    provider == .codex && codexIntegrationMode == .direct
  }

  var isDirectClaude: Bool {
    provider == .claude && claudeIntegrationMode == .direct
  }

  var canSendInput: Bool {
    guard isActive else { return false }
    return isDirect
  }

  var canTakeOver: Bool {
    guard !isDirect else { return false }
    switch provider {
      case .codex: return codexIntegrationMode == .passive
      case .claude: return claudeIntegrationMode != .direct
    }
  }

  var canApprove: Bool {
    canSendInput && attentionReason == .awaitingPermission && pendingApprovalId != nil
  }

  var canAnswer: Bool {
    canSendInput && attentionReason == .awaitingQuestion && pendingApprovalId != nil
  }

  var needsApprovalOverlay: Bool {
    guard isActive, pendingApprovalId != nil else { return false }
    return attentionReason == .awaitingPermission || attentionReason == .awaitingQuestion
  }

  var displayName: String {
    [
      customName,
      summary,
      firstPrompt,
      projectName,
      projectPath.components(separatedBy: "/").last,
    ]
    .compactMap { value -> String? in
      guard let value else { return nil }
      let cleaned = value.strippingXMLTags().trimmingCharacters(in: .whitespacesAndNewlines)
      return cleaned.isEmpty ? nil : cleaned
    }
    .first ?? "Unknown"
  }

  var scopedID: String {
    guard let endpointId else { return id }
    return SessionRef(endpointId: endpointId, sessionId: id).scopedID
  }

  var groupingPath: String {
    repositoryRoot ?? projectPath
  }

  var effectiveContextInputTokens: Int {
    SessionTokenUsageSemantics.effectiveContextInputTokens(
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      snapshotKind: tokenUsageSnapshotKind,
      provider: provider
    )
  }

  var contextFillFraction: Double {
    SessionTokenUsageSemantics.contextFillFraction(
      contextWindow: contextWindow,
      effectiveContextInputTokens: effectiveContextInputTokens
    )
  }

  var contextFillPercent: Double {
    contextFillFraction * 100
  }

  var effectiveCacheHitPercent: Double {
    SessionTokenUsageSemantics.effectiveCacheHitPercent(
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      snapshotKind: tokenUsageSnapshotKind,
      effectiveContextInputTokens: effectiveContextInputTokens
    )
  }

  var hasTokenUsage: Bool {
    SessionTokenUsageSemantics.hasTokenUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens
    )
  }

  var approvalCardContext: ApprovalCardSessionContext {
    ApprovalCardSessionContext(
      id: id,
      projectPath: projectPath,
      isActive: isActive,
      attentionReason: attentionReason,
      pendingApprovalId: pendingApprovalId,
      pendingToolName: pendingToolName,
      pendingToolInput: pendingToolInput,
      canApprove: canApprove,
      canAnswer: canAnswer,
      canTakeOver: canTakeOver,
      canSendInput: canSendInput
    )
  }

  func applyPendingApproval(_ request: ServerApprovalRequest) {
    pendingApproval = request
    applyPendingApprovalProjection(SessionPendingApprovalProjection(request: request))
  }

  func clearPendingApprovalDetails(resetAttention: Bool) {
    pendingApproval = nil
    pendingApprovalId = nil
    pendingToolName = nil
    pendingToolInput = nil
    pendingPermissionDetail = nil
    pendingQuestion = nil

    guard resetAttention else { return }

    if attentionReason == .awaitingPermission || attentionReason == .awaitingQuestion {
      attentionReason = .none
    }
    if workStatus == .permission {
      workStatus = .working
    }
  }

  func applyPendingApprovalProjection(_ projection: SessionPendingApprovalProjection) {
    pendingApprovalId = projection.id
    pendingToolName = projection.toolName
    pendingToolInput = projection.toolInput
    pendingPermissionDetail = projection.permissionDetail
    pendingQuestion = projection.question
    attentionReason = projection.attentionReason
    workStatus = projection.workStatus
  }

  var hasMcpData: Bool {
    !mcpTools.isEmpty || !mcpResources.isEmpty || !mcpResourceTemplates.isEmpty || mcpStartupState != nil
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

  // MARK: - Conversation

  func applyConversationPage(
    rows: [ServerConversationRowEntry],
    hasMoreBefore: Bool,
    oldestSequence: UInt64?,
    isBootstrap: Bool = false
  ) {
    var structureChanged = false

    if isBootstrap {
      rowEntries = rows
      structureChanged = true
    } else {
      for entry in rows {
        structureChanged = upsertRow(entry).structureChanged || structureChanged
      }
    }

    lastChangedRowEntries = rows
    lastRemovedRowIds = []
    hasMoreHistoryBefore = hasMoreBefore
    oldestLoadedSequence = rowEntries.first.map(\.sequence)
    rowEntriesRevision += 1
    rowEntriesContentRevision += 1
    if structureChanged {
      rowEntriesStructureRevision += 1
    }
    conversationLoaded = true
  }

  func applyRowsChanged(
    upserted: [ServerConversationRowEntry],
    removedIds: [String]
  ) {
    var structureChanged = false

    if !removedIds.isEmpty {
      let removed = Set(removedIds)
      rowEntries.removeAll { removed.contains($0.id) }
      structureChanged = true
    }
    for entry in upserted {
      structureChanged = upsertRow(entry).structureChanged || structureChanged
    }

    lastChangedRowEntries = upserted
    lastRemovedRowIds = removedIds
    rowEntriesRevision += 1
    rowEntriesContentRevision += 1
    if structureChanged {
      rowEntriesStructureRevision += 1
    }
  }

  func clearConversation() {
    rowEntries = []
    rowEntriesRevision = 0
    rowEntriesStructureRevision = 0
    rowEntriesContentRevision = 0
    lastChangedRowEntries = []
    lastRemovedRowIds = []
    hasMoreHistoryBefore = false
    isLoadingOlderMessages = false
    conversationLoaded = false
    oldestLoadedSequence = nil
  }

  /// Clear transient state on session end. Keep messages/tokens/history for viewing.
  func clearTransientState() {
    pendingApproval = nil
    pendingApprovalId = nil
    pendingToolName = nil
    pendingToolInput = nil
    pendingPermissionDetail = nil
    pendingQuestion = nil
    undoInProgress = false
    compactInProgress = false
    rollbackInProgress = false
    forkInProgress = false
    pendingShellContext = []
    mcpTools = [:]
    mcpResources = [:]
    mcpResourceTemplates = [:]
    mcpAuthStatuses = [:]
    mcpStartupState = nil
    skills = []
    slashCommands = []
    claudeSkillNames = []
    claudeToolNames = []
    currentTurnId = nil
    permissionMode = .default
    attentionReason = .none
  }

  /// Drop heavy detail payloads when a session is no longer observed.
  func trimInactiveDetailPayloads() {
    turnDiffs = []
    diff = nil
    plan = nil
    currentTurnId = nil
    pendingShellContext = []
    reviewComments = []
    clearConversation()
  }

  private func upsertRow(_ entry: ServerConversationRowEntry) -> ConversationRowMutation {
    if let existingIndex = rowEntries.firstIndex(where: { $0.id == entry.id }) {
      let existingEntry = rowEntries[existingIndex]
      rowEntries.remove(at: existingIndex)
      rowEntries.insert(entry, at: insertionIndex(for: entry.sequence))
      return .updated(structureChanged: existingEntry.sequence != entry
        .sequence || rowTypeKey(for: existingEntry) != rowTypeKey(for: entry))
    }

    guard !rowEntries.isEmpty else {
      rowEntries.append(entry)
      return .inserted
    }

    if let firstSequence = rowEntries.first?.sequence, entry.sequence < firstSequence {
      rowEntries.insert(entry, at: 0)
      return .inserted
    }

    if let lastSequence = rowEntries.last?.sequence, entry.sequence > lastSequence {
      rowEntries.append(entry)
      return .inserted
    }

    rowEntries.insert(entry, at: insertionIndex(for: entry.sequence))
    return .inserted
  }

  private func insertionIndex(for sequence: UInt64) -> Int {
    var low = 0
    var high = rowEntries.count

    while low < high {
      let mid = (low + high) / 2
      if rowEntries[mid].sequence < sequence {
        low = mid + 1
      } else {
        high = mid
      }
    }

    return low
  }

  private func rowTypeKey(for entry: ServerConversationRowEntry) -> String {
    switch entry.row {
      case .user: "user"
      case .steer: "steer"
      case .assistant: "assistant"
      case .thinking: "thinking"
      case .context: "context"
      case .notice: "notice"
      case .shellCommand: "shellCommand"
      case .task: "task"
      case .tool: "tool"
      case .activityGroup: "activityGroup"
      case .question: "question"
      case .approval: "approval"
      case .worker: "worker"
      case .plan: "plan"
      case .hook: "hook"
      case .handoff: "handoff"
      case .system: "system"
    }
  }
}

private enum ConversationRowMutation {
  case inserted
  case updated(structureChanged: Bool)

  var structureChanged: Bool {
    switch self {
      case .inserted:
        true
      case let .updated(structureChanged):
        structureChanged
    }
  }
}

// MARK: - Shell Context

struct ShellContextEntry {
  let command: String
  let output: String
  let exitCode: Int32?
  let timestamp: Date
}
