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

struct ServerTokenUsage: Codable {
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
  let effort: String?

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
    case effort
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
  let messages: [ServerMessage]
  let totalMessageCount: UInt64?
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
    id = try container.decode(String.self, forKey: .id)
    provider = try container.decode(ServerProvider.self, forKey: .provider)
    projectPath = try container.decode(String.self, forKey: .projectPath)
    transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
    projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    customName = try container.decodeIfPresent(String.self, forKey: .customName)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    status = try container.decode(ServerSessionStatus.self, forKey: .status)
    workStatus = try container.decode(ServerWorkStatus.self, forKey: .workStatus)
    messages = try container.decode([ServerMessage].self, forKey: .messages)
    totalMessageCount = try container.decodeIfPresent(UInt64.self, forKey: .totalMessageCount)
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
  let firstPrompt: String??
  let lastMessage: String??
  let model: String??
  let effort: String??
  let permissionMode: String??
  let approvalVersion: UInt64?
  let repositoryRoot: String??
  let isWorktree: Bool?
  let unreadCount: UInt64?

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
    tokenUsageSnapshotKind = try container.decodeIfPresent(ServerTokenUsageSnapshotKind.self, forKey: .tokenUsageSnapshotKind)
    currentDiff = try container.decodePatchValue(String.self, forKey: .currentDiff)
    currentPlan = try container.decodePatchValue(String.self, forKey: .currentPlan)
    customName = try container.decodePatchValue(String.self, forKey: .customName)
    summary = try container.decodePatchValue(String.self, forKey: .summary)
    codexIntegrationMode = try container.decodePatchValue(ServerCodexIntegrationMode.self, forKey: .codexIntegrationMode)
    claudeIntegrationMode = try container.decodePatchValue(ServerClaudeIntegrationMode.self, forKey: .claudeIntegrationMode)
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
    return .some(try decode(T.self, forKey: key))
  }
}
