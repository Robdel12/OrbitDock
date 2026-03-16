//
//  ServerSessionContracts.swift
//  OrbitDock
//
//  Session protocol contracts.
//

import Foundation

// MARK: - Session Status

enum ServerSessionStatus: String, Codable {
  case active
  case ended
}

enum ServerWorkStatus: String, Codable {
  case working
  case waiting
  case permission
  case question
  case reply
  case ended
}

struct ServerTokenUsage: Codable, Equatable {
  let inputTokens: UInt64
  let outputTokens: UInt64
  let cachedTokens: UInt64
  let contextWindow: UInt64

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cachedTokens = "cached_tokens"
    case contextWindow = "context_window"
  }

  var contextFillPercent: Double {
    guard contextWindow > 0 else { return 0 }
    return Double(inputTokens) / Double(contextWindow) * 100
  }

  var cacheHitPercent: Double {
    guard inputTokens > 0 else { return 0 }
    return Double(cachedTokens) / Double(inputTokens) * 100
  }
}

// MARK: - Root Session List

enum ServerSessionListStatus: String, Codable {
  case working
  case permission
  case question
  case reply
  case ended
}

struct ServerSessionListItem: Codable, Identifiable {
  let id: String
  let provider: ServerProvider
  let projectPath: String
  let projectName: String?
  let gitBranch: String?
  let model: String?
  let status: ServerSessionStatus
  let workStatus: ServerWorkStatus
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let claudeIntegrationMode: ServerClaudeIntegrationMode?
  let startedAt: String?
  let lastActivityAt: String?
  let unreadCount: UInt64?
  let hasTurnDiff: Bool?
  let pendingToolName: String?
  let repositoryRoot: String?
  let isWorktree: Bool?
  let worktreeId: String?
  let totalTokens: UInt64?
  let totalCostUSD: Double?
  let displayTitle: String?
  let displayTitleSortKey: String?
  let displaySearchText: String?
  let contextLine: String?
  let listStatus: ServerSessionListStatus?
  let summaryRevision: UInt64?
  let effort: String?
  let activeWorkerCount: UInt64?
  let pendingToolFamily: String?
  let forkedFromSessionId: String?

  init(
    id: String,
    provider: ServerProvider,
    projectPath: String,
    projectName: String?,
    gitBranch: String?,
    model: String?,
    status: ServerSessionStatus,
    workStatus: ServerWorkStatus,
    codexIntegrationMode: ServerCodexIntegrationMode?,
    claudeIntegrationMode: ServerClaudeIntegrationMode?,
    startedAt: String?,
    lastActivityAt: String?,
    unreadCount: UInt64?,
    hasTurnDiff: Bool?,
    pendingToolName: String?,
    repositoryRoot: String?,
    isWorktree: Bool?,
    worktreeId: String?,
    totalTokens: UInt64?,
    totalCostUSD: Double?,
    displayTitle: String?,
    displayTitleSortKey: String?,
    displaySearchText: String?,
    contextLine: String?,
    listStatus: ServerSessionListStatus?,
    summaryRevision: UInt64? = nil,
    effort: String?,
    activeWorkerCount: UInt64? = nil,
    pendingToolFamily: String? = nil,
    forkedFromSessionId: String? = nil
  ) {
    self.id = id
    self.provider = provider
    self.projectPath = projectPath
    self.projectName = projectName
    self.gitBranch = gitBranch
    self.model = model
    self.status = status
    self.workStatus = workStatus
    self.codexIntegrationMode = codexIntegrationMode
    self.claudeIntegrationMode = claudeIntegrationMode
    self.startedAt = startedAt
    self.lastActivityAt = lastActivityAt
    self.unreadCount = unreadCount
    self.hasTurnDiff = hasTurnDiff
    self.pendingToolName = pendingToolName
    self.repositoryRoot = repositoryRoot
    self.isWorktree = isWorktree
    self.worktreeId = worktreeId
    self.totalTokens = totalTokens
    self.totalCostUSD = totalCostUSD
    self.displayTitle = displayTitle
    self.displayTitleSortKey = displayTitleSortKey
    self.displaySearchText = displaySearchText
    self.contextLine = contextLine
    self.listStatus = listStatus
    self.summaryRevision = summaryRevision
    self.effort = effort
    self.activeWorkerCount = activeWorkerCount
    self.pendingToolFamily = pendingToolFamily
    self.forkedFromSessionId = forkedFromSessionId
  }

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case projectPath = "project_path"
    case projectName = "project_name"
    case gitBranch = "git_branch"
    case model
    case status
    case workStatus = "work_status"
    case codexIntegrationMode = "codex_integration_mode"
    case claudeIntegrationMode = "claude_integration_mode"
    case startedAt = "started_at"
    case lastActivityAt = "last_activity_at"
    case unreadCount = "unread_count"
    case hasTurnDiff = "has_turn_diff"
    case pendingToolName = "pending_tool_name"
    case repositoryRoot = "repository_root"
    case isWorktree = "is_worktree"
    case worktreeId = "worktree_id"
    case totalTokens = "total_tokens"
    case totalCostUSD = "total_cost_usd"
    case displayTitle = "display_title"
    case displayTitleSortKey = "display_title_sort_key"
    case displaySearchText = "display_search_text"
    case contextLine = "context_line"
    case listStatus = "list_status"
    case summaryRevision = "summary_revision"
    case effort
    case activeWorkerCount = "active_worker_count"
    case pendingToolFamily = "pending_tool_family"
    case forkedFromSessionId = "forked_from_session_id"
  }
}

// MARK: - Session Summary

struct ServerSessionSummary: Codable, Identifiable {
  let id: String
  let provider: ServerProvider
  let projectPath: String
  let transcriptPath: String?
  let projectName: String?
  let model: String?
  let customName: String?
  let summary: String?
  let status: ServerSessionStatus
  let workStatus: ServerWorkStatus
  let tokenUsage: ServerTokenUsage?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind?
  let hasPendingApproval: Bool
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let claudeIntegrationMode: ServerClaudeIntegrationMode?
  let approvalPolicy: String?
  let sandboxMode: String?
  let permissionMode: String?
  let collaborationMode: String?
  let multiAgent: Bool?
  let personality: String?
  let serviceTier: String?
  let developerInstructions: String?
  let pendingToolName: String?
  let pendingToolInput: String?
  let pendingQuestion: String?
  let pendingApprovalId: String?
  let startedAt: String?
  let lastActivityAt: String?
  let gitBranch: String?
  let gitSha: String?
  let currentCwd: String?
  let firstPrompt: String?
  let lastMessage: String?
  let effort: String?
  let approvalVersion: UInt64?
  let repositoryRoot: String?
  let isWorktree: Bool?
  let worktreeId: String?
  let unreadCount: UInt64?
  let displayTitle: String?
  let displayTitleSortKey: String?
  let displaySearchText: String?
  let contextLine: String?
  let listStatus: String?
  let summaryRevision: UInt64?

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case projectPath = "project_path"
    case transcriptPath = "transcript_path"
    case projectName = "project_name"
    case model
    case customName = "custom_name"
    case summary
    case status
    case workStatus = "work_status"
    case tokenUsage = "token_usage"
    case tokenUsageSnapshotKind = "token_usage_snapshot_kind"
    case hasPendingApproval = "has_pending_approval"
    case codexIntegrationMode = "codex_integration_mode"
    case claudeIntegrationMode = "claude_integration_mode"
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
    case permissionMode = "permission_mode"
    case collaborationMode = "collaboration_mode"
    case multiAgent = "multi_agent"
    case personality
    case serviceTier = "service_tier"
    case developerInstructions = "developer_instructions"
    case pendingToolName = "pending_tool_name"
    case pendingToolInput = "pending_tool_input"
    case pendingQuestion = "pending_question"
    case pendingApprovalId = "pending_approval_id"
    case startedAt = "started_at"
    case lastActivityAt = "last_activity_at"
    case gitBranch = "git_branch"
    case gitSha = "git_sha"
    case currentCwd = "current_cwd"
    case approvalVersion = "approval_version"
    case firstPrompt = "first_prompt"
    case lastMessage = "last_message"
    case effort
    case repositoryRoot = "repository_root"
    case isWorktree = "is_worktree"
    case worktreeId = "worktree_id"
    case unreadCount = "unread_count"
    case displayTitle = "display_title"
    case displayTitleSortKey = "display_title_sort_key"
    case displaySearchText = "display_search_text"
    case contextLine = "context_line"
    case listStatus = "list_status"
    case summaryRevision = "summary_revision"
  }
}

// MARK: - Turn Diffs

struct ServerTurnDiff: Codable {
  let turnId: String
  let diff: String
  let inputTokens: UInt64?
  let outputTokens: UInt64?
  let cachedTokens: UInt64?
  let contextWindow: UInt64?
  let snapshotKind: ServerTokenUsageSnapshotKind?

  enum CodingKeys: String, CodingKey {
    case turnId = "turn_id"
    case diff
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cachedTokens = "cached_tokens"
    case contextWindow = "context_window"
    case snapshotKind = "snapshot_kind"
    case tokenUsage = "token_usage"
  }

  var tokenUsage: ServerTokenUsage? {
    guard let input = inputTokens, let output = outputTokens,
          let cached = cachedTokens, let window = contextWindow,
          input > 0 || output > 0 || window > 0
    else { return nil }
    return ServerTokenUsage(
      inputTokens: input, outputTokens: output,
      cachedTokens: cached, contextWindow: window
    )
  }

  init(
    turnId: String,
    diff: String,
    inputTokens: UInt64? = nil,
    outputTokens: UInt64? = nil,
    cachedTokens: UInt64? = nil,
    contextWindow: UInt64? = nil,
    snapshotKind: ServerTokenUsageSnapshotKind? = nil
  ) {
    self.turnId = turnId
    self.diff = diff
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedTokens = cachedTokens
    self.contextWindow = contextWindow
    self.snapshotKind = snapshotKind
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    turnId = try container.decode(String.self, forKey: .turnId)
    diff = try container.decode(String.self, forKey: .diff)

    // Try flat fields first (TurnDiffSnapshot message)
    var input = try container.decodeIfPresent(UInt64.self, forKey: .inputTokens)
    var output = try container.decodeIfPresent(UInt64.self, forKey: .outputTokens)
    var cached = try container.decodeIfPresent(UInt64.self, forKey: .cachedTokens)
    var window = try container.decodeIfPresent(UInt64.self, forKey: .contextWindow)
    var snapshotKind = try container.decodeIfPresent(ServerTokenUsageSnapshotKind.self, forKey: .snapshotKind)

    // Fall back to nested token_usage object (SessionState.turn_diffs)
    if input == nil, let nested = try container.decodeIfPresent(ServerTokenUsage.self, forKey: .tokenUsage) {
      input = nested.inputTokens
      output = nested.outputTokens
      cached = nested.cachedTokens
      window = nested.contextWindow
    }

    if snapshotKind == nil {
      snapshotKind = .unknown
    }

    inputTokens = input
    outputTokens = output
    cachedTokens = cached
    contextWindow = window
    self.snapshotKind = snapshotKind
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(turnId, forKey: .turnId)
    try container.encode(diff, forKey: .diff)
    try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
    try container.encodeIfPresent(outputTokens, forKey: .outputTokens)
    try container.encodeIfPresent(cachedTokens, forKey: .cachedTokens)
    try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
    try container.encodeIfPresent(snapshotKind, forKey: .snapshotKind)
  }
}

// MARK: - Subagent Types

enum ServerSubagentStatus: String, Codable {
  case pending
  case running
  case completed
  case failed
  case cancelled
  case shutdown
  case notFound = "not_found"
}

struct ServerSubagentInfo: Codable, Identifiable {
  let id: String
  let agentType: String
  let startedAt: String
  let endedAt: String?
  let provider: ServerProvider?
  let label: String?
  let status: ServerSubagentStatus?
  let taskSummary: String?
  let resultSummary: String?
  let errorSummary: String?
  let parentSubagentId: String?
  let model: String?
  let lastActivityAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case agentType = "agent_type"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case provider
    case label
    case status
    case taskSummary = "task_summary"
    case resultSummary = "result_summary"
    case errorSummary = "error_summary"
    case parentSubagentId = "parent_subagent_id"
    case model
    case lastActivityAt = "last_activity_at"
  }
}

struct ServerSubagentTool: Codable, Identifiable {
  let id: String
  let toolName: String
  let summary: String
  let output: String?
  let isInProgress: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case toolName = "tool_name"
    case summary
    case output
    case isInProgress = "is_in_progress"
  }
}

// MARK: - Session State

struct ServerSessionState: Codable, Identifiable {
  let id: String
  let provider: ServerProvider
  let projectPath: String
  let transcriptPath: String?
  let projectName: String?
  let model: String?
  let customName: String?
  let summary: String?
  let status: ServerSessionStatus
  let workStatus: ServerWorkStatus
  let rows: [ServerConversationRowEntry]
  let totalRowCount: UInt64?
  let hasMoreBefore: Bool?
  let oldestSequence: UInt64?
  let newestSequence: UInt64?
  let pendingApproval: ServerApprovalRequest?
  let tokenUsage: ServerTokenUsage
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind
  let currentDiff: String?
  let currentPlan: String?
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let claudeIntegrationMode: ServerClaudeIntegrationMode?
  let approvalPolicy: String?
  let sandboxMode: String?
  let permissionMode: String?
  let collaborationMode: String?
  let multiAgent: Bool?
  let personality: String?
  let serviceTier: String?
  let developerInstructions: String?
  let pendingToolName: String?
  let pendingToolInput: String?
  let pendingQuestion: String?
  let pendingApprovalId: String?
  let startedAt: String?
  let lastActivityAt: String?
  let forkedFromSessionId: String?
  let revision: UInt64?
  let currentTurnId: String?
  let turnCount: UInt64
  let turnDiffs: [ServerTurnDiff]
  let gitBranch: String?
  let gitSha: String?
  let currentCwd: String?
  let firstPrompt: String?
  let lastMessage: String?
  let subagents: [ServerSubagentInfo]
  let effort: String?
  let terminalSessionId: String?
  let terminalApp: String?
  let approvalVersion: UInt64?
  let repositoryRoot: String?
  let isWorktree: Bool?
  let worktreeId: String?
  let unreadCount: UInt64?

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case projectPath = "project_path"
    case transcriptPath = "transcript_path"
    case projectName = "project_name"
    case model
    case customName = "custom_name"
    case summary
    case status
    case workStatus = "work_status"
    case messages
    case rows
    case totalRowCount = "total_row_count"
    case totalMessageCount = "total_message_count"
    case hasMoreBefore = "has_more_before"
    case oldestSequence = "oldest_sequence"
    case newestSequence = "newest_sequence"
    case pendingApproval = "pending_approval"
    case tokenUsage = "token_usage"
    case tokenUsageSnapshotKind = "token_usage_snapshot_kind"
    case currentDiff = "current_diff"
    case currentPlan = "current_plan"
    case codexIntegrationMode = "codex_integration_mode"
    case claudeIntegrationMode = "claude_integration_mode"
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
    case permissionMode = "permission_mode"
    case collaborationMode = "collaboration_mode"
    case multiAgent = "multi_agent"
    case personality
    case serviceTier = "service_tier"
    case developerInstructions = "developer_instructions"
    case pendingToolName = "pending_tool_name"
    case pendingToolInput = "pending_tool_input"
    case pendingQuestion = "pending_question"
    case pendingApprovalId = "pending_approval_id"
    case startedAt = "started_at"
    case lastActivityAt = "last_activity_at"
    case forkedFromSessionId = "forked_from_session_id"
    case revision
    case currentTurnId = "current_turn_id"
    case turnCount = "turn_count"
    case turnDiffs = "turn_diffs"
    case gitBranch = "git_branch"
    case gitSha = "git_sha"
    case currentCwd = "current_cwd"
    case firstPrompt = "first_prompt"
    case lastMessage = "last_message"
    case subagents
    case effort
    case terminalSessionId = "terminal_session_id"
    case terminalApp = "terminal_app"
    case approvalVersion = "approval_version"
    case repositoryRoot = "repository_root"
    case isWorktree = "is_worktree"
    case worktreeId = "worktree_id"
    case unreadCount = "unread_count"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedID = try container.decode(String.self, forKey: .id)
    id = decodedID
    provider = try container.decode(ServerProvider.self, forKey: .provider)
    projectPath = try container.decode(String.self, forKey: .projectPath)
    transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
    projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    customName = try container.decodeIfPresent(String.self, forKey: .customName)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    status = try container.decode(ServerSessionStatus.self, forKey: .status)
    workStatus = try container.decode(ServerWorkStatus.self, forKey: .workStatus)
    rows = try container.decodeIfPresent([ServerConversationRowEntry].self, forKey: .rows) ?? []
    let directTotalRowCount = try container.decodeIfPresent(UInt64.self, forKey: .totalRowCount)
    let legacyTotalMessageCount = try container.decodeIfPresent(UInt64.self, forKey: .totalMessageCount)
    totalRowCount = directTotalRowCount ?? legacyTotalMessageCount
    hasMoreBefore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreBefore)
    oldestSequence = try container.decodeIfPresent(UInt64.self, forKey: .oldestSequence)
    newestSequence = try container.decodeIfPresent(UInt64.self, forKey: .newestSequence)
    pendingApproval = try container.decodeIfPresent(ServerApprovalRequest.self, forKey: .pendingApproval)
    tokenUsage = try container.decode(ServerTokenUsage.self, forKey: .tokenUsage)
    tokenUsageSnapshotKind =
      try container.decodeIfPresent(ServerTokenUsageSnapshotKind.self, forKey: .tokenUsageSnapshotKind) ?? .unknown
    currentDiff = try container.decodeIfPresent(String.self, forKey: .currentDiff)
    currentPlan = try container.decodeIfPresent(String.self, forKey: .currentPlan)
    codexIntegrationMode = try container.decodeIfPresent(ServerCodexIntegrationMode.self, forKey: .codexIntegrationMode)
    claudeIntegrationMode = try container.decodeIfPresent(
      ServerClaudeIntegrationMode.self,
      forKey: .claudeIntegrationMode
    )
    approvalPolicy = try container.decodeIfPresent(String.self, forKey: .approvalPolicy)
    sandboxMode = try container.decodeIfPresent(String.self, forKey: .sandboxMode)
    permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
    collaborationMode = try container.decodeIfPresent(String.self, forKey: .collaborationMode)
    multiAgent = try container.decodeIfPresent(Bool.self, forKey: .multiAgent)
    personality = try container.decodeIfPresent(String.self, forKey: .personality)
    serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
    developerInstructions = try container.decodeIfPresent(String.self, forKey: .developerInstructions)
    pendingToolName = try container.decodeIfPresent(String.self, forKey: .pendingToolName)
    pendingToolInput = try container.decodeIfPresent(String.self, forKey: .pendingToolInput)
    pendingQuestion = try container.decodeIfPresent(String.self, forKey: .pendingQuestion)
    pendingApprovalId = try container.decodeIfPresent(String.self, forKey: .pendingApprovalId)
    startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
    lastActivityAt = try container.decodeIfPresent(String.self, forKey: .lastActivityAt)
    forkedFromSessionId = try container.decodeIfPresent(String.self, forKey: .forkedFromSessionId)
    revision = try container.decodeIfPresent(UInt64.self, forKey: .revision)
    currentTurnId = try container.decodeIfPresent(String.self, forKey: .currentTurnId)
    turnCount = try container.decodeIfPresent(UInt64.self, forKey: .turnCount) ?? 0
    turnDiffs = try container.decodeIfPresent([ServerTurnDiff].self, forKey: .turnDiffs) ?? []
    gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
    gitSha = try container.decodeIfPresent(String.self, forKey: .gitSha)
    currentCwd = try container.decodeIfPresent(String.self, forKey: .currentCwd)
    firstPrompt = try container.decodeIfPresent(String.self, forKey: .firstPrompt)
    lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
    subagents = try container.decodeIfPresent([ServerSubagentInfo].self, forKey: .subagents) ?? []
    effort = try container.decodeIfPresent(String.self, forKey: .effort)
    terminalSessionId = try container.decodeIfPresent(String.self, forKey: .terminalSessionId)
    terminalApp = try container.decodeIfPresent(String.self, forKey: .terminalApp)
    approvalVersion = try container.decodeIfPresent(UInt64.self, forKey: .approvalVersion)
    repositoryRoot = try container.decodeIfPresent(String.self, forKey: .repositoryRoot)
    isWorktree = try container.decodeIfPresent(Bool.self, forKey: .isWorktree)
    worktreeId = try container.decodeIfPresent(String.self, forKey: .worktreeId)
    unreadCount = try container.decodeIfPresent(UInt64.self, forKey: .unreadCount)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(provider, forKey: .provider)
    try container.encode(projectPath, forKey: .projectPath)
    try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
    try container.encodeIfPresent(projectName, forKey: .projectName)
    try container.encodeIfPresent(model, forKey: .model)
    try container.encodeIfPresent(customName, forKey: .customName)
    try container.encodeIfPresent(summary, forKey: .summary)
    try container.encode(status, forKey: .status)
    try container.encode(workStatus, forKey: .workStatus)
    try container.encode(rows, forKey: .rows)
    try container.encodeIfPresent(totalRowCount, forKey: .totalRowCount)
    try container.encodeIfPresent(hasMoreBefore, forKey: .hasMoreBefore)
    try container.encodeIfPresent(oldestSequence, forKey: .oldestSequence)
    try container.encodeIfPresent(newestSequence, forKey: .newestSequence)
    try container.encodeIfPresent(pendingApproval, forKey: .pendingApproval)
    try container.encode(tokenUsage, forKey: .tokenUsage)
    try container.encode(tokenUsageSnapshotKind, forKey: .tokenUsageSnapshotKind)
    try container.encodeIfPresent(currentDiff, forKey: .currentDiff)
    try container.encodeIfPresent(currentPlan, forKey: .currentPlan)
    try container.encodeIfPresent(codexIntegrationMode, forKey: .codexIntegrationMode)
    try container.encodeIfPresent(claudeIntegrationMode, forKey: .claudeIntegrationMode)
    try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
    try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)
    try container.encodeIfPresent(permissionMode, forKey: .permissionMode)
    try container.encodeIfPresent(collaborationMode, forKey: .collaborationMode)
    try container.encodeIfPresent(multiAgent, forKey: .multiAgent)
    try container.encodeIfPresent(personality, forKey: .personality)
    try container.encodeIfPresent(serviceTier, forKey: .serviceTier)
    try container.encodeIfPresent(developerInstructions, forKey: .developerInstructions)
    try container.encodeIfPresent(pendingToolName, forKey: .pendingToolName)
    try container.encodeIfPresent(pendingToolInput, forKey: .pendingToolInput)
    try container.encodeIfPresent(pendingQuestion, forKey: .pendingQuestion)
    try container.encodeIfPresent(pendingApprovalId, forKey: .pendingApprovalId)
    try container.encodeIfPresent(startedAt, forKey: .startedAt)
    try container.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
    try container.encodeIfPresent(forkedFromSessionId, forKey: .forkedFromSessionId)
    try container.encodeIfPresent(revision, forKey: .revision)
    try container.encodeIfPresent(currentTurnId, forKey: .currentTurnId)
    try container.encode(turnCount, forKey: .turnCount)
    try container.encode(turnDiffs, forKey: .turnDiffs)
    try container.encodeIfPresent(gitBranch, forKey: .gitBranch)
    try container.encodeIfPresent(gitSha, forKey: .gitSha)
    try container.encodeIfPresent(currentCwd, forKey: .currentCwd)
    try container.encodeIfPresent(firstPrompt, forKey: .firstPrompt)
    try container.encodeIfPresent(lastMessage, forKey: .lastMessage)
    try container.encode(subagents, forKey: .subagents)
    try container.encodeIfPresent(effort, forKey: .effort)
    try container.encodeIfPresent(terminalSessionId, forKey: .terminalSessionId)
    try container.encodeIfPresent(terminalApp, forKey: .terminalApp)
    try container.encodeIfPresent(approvalVersion, forKey: .approvalVersion)
    try container.encodeIfPresent(repositoryRoot, forKey: .repositoryRoot)
    try container.encodeIfPresent(isWorktree, forKey: .isWorktree)
    try container.encodeIfPresent(worktreeId, forKey: .worktreeId)
    try container.encodeIfPresent(unreadCount, forKey: .unreadCount)
  }
}

// MARK: - Session Capabilities

struct ServerConversationSearchQuery: Sendable, Equatable {
  var text: String?
  var family: ServerConversationToolFamily?
  var status: ServerConversationToolStatus?
  var kind: ServerConversationToolKind?

  init(
    text: String? = nil,
    family: ServerConversationToolFamily? = nil,
    status: ServerConversationToolStatus? = nil,
    kind: ServerConversationToolKind? = nil
  ) {
    self.text = text
    self.family = family
    self.status = status
    self.kind = kind
  }
}

struct ServerSessionStats: Decodable, Sendable {
  let sessionId: String
  let totalRows: UInt64
  let toolCount: UInt64
  let toolCountByFamily: [String: UInt64]
  let failedToolCount: UInt64
  let averageToolDurationMs: UInt64
  let turnCount: UInt64
  let totalTokens: ServerTokenUsage
  let workerCount: UInt32
  let durationMs: UInt64

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case totalRows = "total_rows"
    case toolCount = "tool_count"
    case toolCountByFamily = "tool_count_by_family"
    case failedToolCount = "failed_tool_count"
    case averageToolDurationMs = "average_tool_duration_ms"
    case turnCount = "turn_count"
    case totalTokens = "total_tokens"
    case workerCount = "worker_count"
    case durationMs = "duration_ms"
  }
}

struct ServerSessionInstructionsPayload: Decodable, Sendable {
  let claudeMD: String?
  let systemPrompt: String?
  let developerInstructions: String?

  enum CodingKeys: String, CodingKey {
    case claudeMD = "claude_md"
    case systemPrompt = "system_prompt"
    case developerInstructions = "developer_instructions"
  }
}

struct ServerSessionInstructions: Decodable, Sendable {
  let sessionId: String
  let provider: ServerProvider
  let instructions: ServerSessionInstructionsPayload

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case provider
    case instructions
  }
}

// MARK: - Delta Updates

struct ServerStateChanges: Codable {
  let status: ServerSessionStatus?
  let workStatus: ServerWorkStatus?
  let pendingApproval: ServerApprovalRequest??
  let tokenUsage: ServerTokenUsage?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind?
  let currentDiff: String??
  let currentPlan: String??
  let customName: String??
  let summary: String??
  let codexIntegrationMode: ServerCodexIntegrationMode??
  let claudeIntegrationMode: ServerClaudeIntegrationMode??
  let approvalPolicy: String??
  let sandboxMode: String??
  let collaborationMode: String??
  let multiAgent: Bool??
  let personality: String??
  let serviceTier: String??
  let developerInstructions: String??
  let lastActivityAt: String?
  let currentTurnId: String??
  let turnCount: UInt64?
  let gitBranch: String??
  let gitSha: String??
  let currentCwd: String??
  let subagents: [ServerSubagentInfo]?
  let firstPrompt: String??
  let lastMessage: String??
  let model: String??
  let effort: String??
  let permissionMode: String??
  let approvalVersion: UInt64?
  let repositoryRoot: String??
  let isWorktree: Bool?
  let unreadCount: UInt64?

  init(
    status: ServerSessionStatus? = nil,
    workStatus: ServerWorkStatus? = nil,
    pendingApproval: ServerApprovalRequest?? = nil,
    tokenUsage: ServerTokenUsage? = nil,
    tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind? = nil,
    currentDiff: String?? = nil,
    currentPlan: String?? = nil,
    customName: String?? = nil,
    summary: String?? = nil,
    codexIntegrationMode: ServerCodexIntegrationMode?? = nil,
    claudeIntegrationMode: ServerClaudeIntegrationMode?? = nil,
    approvalPolicy: String?? = nil,
    sandboxMode: String?? = nil,
    collaborationMode: String?? = nil,
    multiAgent: Bool?? = nil,
    personality: String?? = nil,
    serviceTier: String?? = nil,
    developerInstructions: String?? = nil,
    lastActivityAt: String? = nil,
    currentTurnId: String?? = nil,
    turnCount: UInt64? = nil,
    gitBranch: String?? = nil,
    gitSha: String?? = nil,
    currentCwd: String?? = nil,
    subagents: [ServerSubagentInfo]? = nil,
    firstPrompt: String?? = nil,
    lastMessage: String?? = nil,
    model: String?? = nil,
    effort: String?? = nil,
    permissionMode: String?? = nil,
    approvalVersion: UInt64? = nil,
    repositoryRoot: String?? = nil,
    isWorktree: Bool? = nil,
    unreadCount: UInt64? = nil
  ) {
    self.status = status
    self.workStatus = workStatus
    self.pendingApproval = pendingApproval
    self.tokenUsage = tokenUsage
    self.tokenUsageSnapshotKind = tokenUsageSnapshotKind
    self.currentDiff = currentDiff
    self.currentPlan = currentPlan
    self.customName = customName
    self.summary = summary
    self.codexIntegrationMode = codexIntegrationMode
    self.claudeIntegrationMode = claudeIntegrationMode
    self.approvalPolicy = approvalPolicy
    self.sandboxMode = sandboxMode
    self.collaborationMode = collaborationMode
    self.multiAgent = multiAgent
    self.personality = personality
    self.serviceTier = serviceTier
    self.developerInstructions = developerInstructions
    self.lastActivityAt = lastActivityAt
    self.currentTurnId = currentTurnId
    self.turnCount = turnCount
    self.gitBranch = gitBranch
    self.gitSha = gitSha
    self.currentCwd = currentCwd
    self.subagents = subagents
    self.firstPrompt = firstPrompt
    self.lastMessage = lastMessage
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.approvalVersion = approvalVersion
    self.repositoryRoot = repositoryRoot
    self.isWorktree = isWorktree
    self.unreadCount = unreadCount
  }

  enum CodingKeys: String, CodingKey {
    case status
    case workStatus = "work_status"
    case pendingApproval = "pending_approval"
    case tokenUsage = "token_usage"
    case tokenUsageSnapshotKind = "token_usage_snapshot_kind"
    case currentDiff = "current_diff"
    case currentPlan = "current_plan"
    case customName = "custom_name"
    case summary
    case codexIntegrationMode = "codex_integration_mode"
    case claudeIntegrationMode = "claude_integration_mode"
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
    case collaborationMode = "collaboration_mode"
    case multiAgent = "multi_agent"
    case personality
    case serviceTier = "service_tier"
    case developerInstructions = "developer_instructions"
    case lastActivityAt = "last_activity_at"
    case currentTurnId = "current_turn_id"
    case turnCount = "turn_count"
    case gitBranch = "git_branch"
    case gitSha = "git_sha"
    case currentCwd = "current_cwd"
    case subagents
    case firstPrompt = "first_prompt"
    case lastMessage = "last_message"
    case model
    case effort
    case permissionMode = "permission_mode"
    case approvalVersion = "approval_version"
    case repositoryRoot = "repository_root"
    case isWorktree = "is_worktree"
    case unreadCount = "unread_count"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decodeIfPresent(ServerSessionStatus.self, forKey: .status)
    workStatus = try container.decodeIfPresent(ServerWorkStatus.self, forKey: .workStatus)
    pendingApproval = try container.decodePatchValue(ServerApprovalRequest.self, forKey: .pendingApproval)
    tokenUsage = try container.decodeIfPresent(ServerTokenUsage.self, forKey: .tokenUsage)
    tokenUsageSnapshotKind = try container.decodeIfPresent(
      ServerTokenUsageSnapshotKind.self,
      forKey: .tokenUsageSnapshotKind
    )
    currentDiff = try container.decodePatchValue(String.self, forKey: .currentDiff)
    currentPlan = try container.decodePatchValue(String.self, forKey: .currentPlan)
    customName = try container.decodePatchValue(String.self, forKey: .customName)
    summary = try container.decodePatchValue(String.self, forKey: .summary)
    codexIntegrationMode = try container.decodePatchValue(
      ServerCodexIntegrationMode.self,
      forKey: .codexIntegrationMode
    )
    claudeIntegrationMode = try container.decodePatchValue(
      ServerClaudeIntegrationMode.self,
      forKey: .claudeIntegrationMode
    )
    approvalPolicy = try container.decodePatchValue(String.self, forKey: .approvalPolicy)
    sandboxMode = try container.decodePatchValue(String.self, forKey: .sandboxMode)
    collaborationMode = try container.decodePatchValue(String.self, forKey: .collaborationMode)
    multiAgent = try container.decodePatchValue(Bool.self, forKey: .multiAgent)
    personality = try container.decodePatchValue(String.self, forKey: .personality)
    serviceTier = try container.decodePatchValue(String.self, forKey: .serviceTier)
    developerInstructions = try container.decodePatchValue(String.self, forKey: .developerInstructions)
    lastActivityAt = try container.decodeIfPresent(String.self, forKey: .lastActivityAt)
    currentTurnId = try container.decodePatchValue(String.self, forKey: .currentTurnId)
    turnCount = try container.decodeIfPresent(UInt64.self, forKey: .turnCount)
    gitBranch = try container.decodePatchValue(String.self, forKey: .gitBranch)
    gitSha = try container.decodePatchValue(String.self, forKey: .gitSha)
    currentCwd = try container.decodePatchValue(String.self, forKey: .currentCwd)
    subagents = try container.decodeIfPresent([ServerSubagentInfo].self, forKey: .subagents)
    firstPrompt = try container.decodePatchValue(String.self, forKey: .firstPrompt)
    lastMessage = try container.decodePatchValue(String.self, forKey: .lastMessage)
    model = try container.decodePatchValue(String.self, forKey: .model)
    effort = try container.decodePatchValue(String.self, forKey: .effort)
    permissionMode = try container.decodePatchValue(String.self, forKey: .permissionMode)
    approvalVersion = try container.decodeIfPresent(UInt64.self, forKey: .approvalVersion)
    repositoryRoot = try container.decodePatchValue(String.self, forKey: .repositoryRoot)
    isWorktree = try container.decodeIfPresent(Bool.self, forKey: .isWorktree)
    unreadCount = try container.decodeIfPresent(UInt64.self, forKey: .unreadCount)
  }
}

private extension KeyedDecodingContainer where Key == ServerStateChanges.CodingKeys {
  func decodePatchValue<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T?? {
    guard contains(key) else { return nil }
    if try decodeNil(forKey: key) {
      return .some(nil)
    }
    return try .some(decode(T.self, forKey: key))
  }
}
