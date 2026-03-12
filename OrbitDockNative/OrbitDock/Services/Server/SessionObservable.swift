//
//  SessionObservable.swift
//  OrbitDock
//
//  Per-session @Observable detail state for non-conversation session data.
//  Conversation payload and hydration live in ConversationStore so the client
//  has one authoritative owner for transcript recovery and rendering.
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
  var plan: String?
  var autonomy: AutonomyLevel = .autonomous
  var autonomyConfiguredOnServer: Bool = true
  var permissionMode: ClaudePermissionMode = .default
  var collaborationMode: String?
  var multiAgent: Bool?
  var personality: String?
  var serviceTier: String?
  var developerInstructions: String?
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
  var subagentMessages: [String: [ServerMessage]] = [:] // keyed by subagent ID

  /// Shell context buffer — auto-prepended to next sendMessage
  var pendingShellContext: [ShellContextEntry] = []

  // Operation flags
  var undoInProgress: Bool = false
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
      case .none: return workStatus == .working ? .working : .reply
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

  var detailSessionSnapshot: Session {
    var session = Session(
      id: id,
      endpointId: endpointId,
      endpointName: endpointName,
      projectPath: projectPath,
      projectName: projectName,
      branch: branch,
      model: model,
      summary: summary,
      customName: customName,
      firstPrompt: firstPrompt,
      transcriptPath: transcriptPath,
      status: status,
      workStatus: workStatus,
      startedAt: startedAt,
      endedAt: endedAt,
      endReason: endReason,
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      lastActivityAt: lastActivityAt,
      lastFilesPersistedAt: lastFilesPersistedAt,
      lastTool: lastTool,
      lastToolAt: lastToolAt,
      promptCount: promptCount,
      toolCount: toolCount,
      attentionReason: attentionReason,
      pendingToolName: pendingToolName,
      pendingToolInput: pendingToolInput,
      pendingPermissionDetail: pendingPermissionDetail,
      pendingQuestion: pendingQuestion,
      provider: provider,
      codexIntegrationMode: codexIntegrationMode,
      claudeIntegrationMode: claudeIntegrationMode,
      codexThreadId: codexThreadId,
      pendingApprovalId: pendingApprovalId,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens,
      contextWindow: contextWindow,
      tokenUsageSnapshotKind: tokenUsageSnapshotKind,
      displayName: displayName,
      normalizedDisplayName: displayName.lowercased(),
      displaySearchText: displayName.lowercased()
    )
    session.endpointConnectionStatus = endpointConnectionStatus
    session.lastMessage = lastMessage
    session.effort = effort
    session.collaborationMode = collaborationMode
    session.multiAgent = multiAgent
    session.personality = personality
    session.serviceTier = serviceTier
    session.developerInstructions = developerInstructions
    session.gitSha = gitSha
    session.currentCwd = currentCwd
    session.repositoryRoot = repositoryRoot
    session.isWorktree = isWorktree
    session.worktreeId = worktreeId
    session.unreadCount = unreadCount
    session.displaySearchText = [
      displayName,
      projectName,
      branch,
      model,
      summary,
      firstPrompt,
      lastMessage,
      projectPath,
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: " ")
    .lowercased()
    return session
  }

  func applySession(_ session: Session) {
    applySnapshotProjection(SessionDetailSnapshotProjection.from(session))
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

  /// Clear transient state on session end. Keep messages/tokens/history for viewing.
  func clearTransientState() {
    pendingApproval = nil
    pendingApprovalId = nil
    pendingToolName = nil
    pendingToolInput = nil
    pendingPermissionDetail = nil
    pendingQuestion = nil
    undoInProgress = false
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
    diff = nil
    plan = nil
    currentTurnId = nil
    permissionMode = .default
    attentionReason = .none
  }

  /// Drop heavy non-conversation detail payloads when a session is no longer observed.
  /// Conversation history is owned by ConversationStore.
  func trimInactiveDetailPayloads() {
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
