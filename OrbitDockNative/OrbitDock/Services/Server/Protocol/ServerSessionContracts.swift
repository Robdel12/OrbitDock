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

enum ServerSessionControlMode: String, Codable {
  case direct
  case passive
}

enum ServerSessionLifecycleState: String, Codable {
  case open
  case resumable
  case ended
}

enum ServerCodexConfigSource: String, Codable, CaseIterable, Hashable, Sendable {
  case orbitdock
  case user
}

enum ServerCodexConfigMode: String, Codable, CaseIterable, Hashable, Sendable {
  case inherit
  case profile
  case custom
}

enum ServerCodexApprovalMode: String, Codable, Equatable, Hashable, Sendable {
  case untrusted
  case onFailure = "on_failure"
  case onRequest = "on_request"
  case never
}

struct ServerCodexGranularApprovalPolicy: Codable, Equatable, Hashable, Sendable {
  let sandboxApproval: Bool?
  let rules: Bool?
  let skillApproval: Bool?
  let requestPermissions: Bool?
  let mcpElicitations: Bool?

  enum CodingKeys: String, CodingKey {
    case sandboxApproval = "sandbox_approval"
    case rules
    case skillApproval = "skill_approval"
    case requestPermissions = "request_permissions"
    case mcpElicitations = "mcp_elicitations"
  }
}

enum ServerCodexApprovalPolicy: Codable, Equatable, Hashable, Sendable {
  case mode(ServerCodexApprovalMode)
  case granular(ServerCodexGranularApprovalPolicy)

  private enum CodingKeys: String, CodingKey {
    case mode
    case granular
  }

  init(from decoder: Decoder) throws {
    let singleValueContainer = try decoder.singleValueContainer()
    if let legacyMode = try? singleValueContainer.decode(String.self),
       let mode = ServerCodexApprovalMode(serverValue: legacyMode)
    {
      self = .mode(mode)
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let mode = try container.decodeIfPresent(ServerCodexApprovalMode.self, forKey: .mode) {
      self = .mode(mode)
      return
    }
    if let granular = try container.decodeIfPresent(
      ServerCodexGranularApprovalPolicy.self,
      forKey: .granular
    ) {
      self = .granular(granular)
      return
    }
    throw DecodingError.dataCorrupted(
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Expected mode or granular Codex approval policy"
      )
    )
  }

  func encode(to encoder: Encoder) throws {
    switch self {
      case let .mode(mode):
        var container = encoder.singleValueContainer()
        try container.encode(mode.legacySummary)
      case let .granular(granular):
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(granular, forKey: .granular)
    }
  }
}

private extension ServerCodexApprovalMode {
  init?(serverValue: String) {
    switch serverValue {
      case "untrusted":
        self = .untrusted
      case "on-failure", "on_failure":
        self = .onFailure
      case "on-request", "on_request":
        self = .onRequest
      case "never":
        self = .never
      default:
        return nil
    }
  }
}

struct ServerCodexSessionOverrides: Codable, Equatable, Hashable, Sendable {
  let model: String?
  let modelProvider: String?
  let approvalPolicy: String?
  let approvalPolicyDetails: ServerCodexApprovalPolicy?
  let sandboxMode: String?
  let collaborationMode: String?
  let multiAgent: Bool?
  let personality: String?
  let serviceTier: String?
  let developerInstructions: String?
  let effort: String?

  enum CodingKeys: String, CodingKey {
    case model
    case modelProvider = "model_provider"
    case approvalPolicy = "approval_policy"
    case approvalPolicyDetails = "approval_policy_details"
    case sandboxMode = "sandbox_mode"
    case collaborationMode = "collaboration_mode"
    case multiAgent = "multi_agent"
    case personality
    case serviceTier = "service_tier"
    case developerInstructions = "developer_instructions"
    case effort
  }
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
  let controlMode: ServerSessionControlMode
  let lifecycleState: ServerSessionLifecycleState
  let steerable: Bool
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let claudeIntegrationMode: ServerClaudeIntegrationMode?
  let startedAt: String?
  let lastActivityAt: String?
  let unreadCount: UInt64
  let hasTurnDiff: Bool
  let pendingToolName: String?
  let repositoryRoot: String?
  let isWorktree: Bool
  let worktreeId: String?
  let totalTokens: UInt64
  let totalCostUSD: Double
  let inputTokens: UInt64
  let outputTokens: UInt64
  let cachedTokens: UInt64
  let displayTitle: String
  let displayTitleSortKey: String?
  let displaySearchText: String?
  let contextLine: String?
  let listStatus: ServerSessionListStatus
  let summaryRevision: UInt64
  let effort: String?
  let activeWorkerCount: UInt64
  let pendingToolFamily: String?
  let forkedFromSessionId: String?
  let missionId: String?
  let issueIdentifier: String?

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case projectPath = "project_path"
    case projectName = "project_name"
    case gitBranch = "git_branch"
    case model
    case status
    case workStatus = "work_status"
    case controlMode = "control_mode"
    case lifecycleState = "lifecycle_state"
    case steerable
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
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cachedTokens = "cached_tokens"
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
    case missionId = "mission_id"
    case issueIdentifier = "issue_identifier"
  }
}

struct ServerDashboardDiffPreview: Codable, Equatable {
  let fileCount: UInt32
  let additions: UInt32
  let deletions: UInt32
  var filePaths: [String] = []

  enum CodingKeys: String, CodingKey {
    case fileCount = "file_count"
    case additions
    case deletions
    case filePaths = "file_paths"
  }
}

struct ServerDashboardConversationItem: Codable, Identifiable, Equatable {
  let sessionId: String
  let provider: ServerProvider
  let projectPath: String
  let projectName: String?
  let repositoryRoot: String?
  let gitBranch: String?
  let isWorktree: Bool
  let worktreeId: String?
  let model: String?
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let claudeIntegrationMode: ServerClaudeIntegrationMode?
  let status: ServerSessionStatus
  let workStatus: ServerWorkStatus
  let controlMode: ServerSessionControlMode
  let lifecycleState: ServerSessionLifecycleState
  let listStatus: ServerSessionListStatus
  let displayTitle: String
  let contextLine: String?
  let lastMessage: String?
  let previewText: String?
  let activitySummary: String?
  let alertContext: String?
  let startedAt: String?
  let lastActivityAt: String?
  let unreadCount: UInt64
  let hasTurnDiff: Bool
  let diffPreview: ServerDashboardDiffPreview?
  let pendingToolName: String?
  let pendingToolInput: String?
  let pendingQuestion: String?
  let toolCount: UInt64
  let activeWorkerCount: UInt32
  let issueIdentifier: String?
  let effort: String?

  var id: String {
    sessionId
  }

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case provider
    case projectPath = "project_path"
    case projectName = "project_name"
    case repositoryRoot = "repository_root"
    case gitBranch = "git_branch"
    case isWorktree = "is_worktree"
    case worktreeId = "worktree_id"
    case model
    case codexIntegrationMode = "codex_integration_mode"
    case claudeIntegrationMode = "claude_integration_mode"
    case status
    case workStatus = "work_status"
    case controlMode = "control_mode"
    case lifecycleState = "lifecycle_state"
    case listStatus = "list_status"
    case displayTitle = "display_title"
    case contextLine = "context_line"
    case lastMessage = "last_message"
    case previewText = "preview_text"
    case activitySummary = "activity_summary"
    case alertContext = "alert_context"
    case startedAt = "started_at"
    case lastActivityAt = "last_activity_at"
    case unreadCount = "unread_count"
    case hasTurnDiff = "has_turn_diff"
    case diffPreview = "diff_preview"
    case pendingToolName = "pending_tool_name"
    case pendingToolInput = "pending_tool_input"
    case pendingQuestion = "pending_question"
    case toolCount = "tool_count"
    case activeWorkerCount = "active_worker_count"
    case issueIdentifier = "issue_identifier"
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
  let controlMode: ServerSessionControlMode
  let lifecycleState: ServerSessionLifecycleState
  let acceptsUserInput: Bool
  let steerable: Bool
  let tokenUsage: ServerTokenUsage
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind
  let hasPendingApproval: Bool
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let claudeIntegrationMode: ServerClaudeIntegrationMode?
  let approvalPolicy: String?
  let approvalPolicyDetails: ServerCodexApprovalPolicy?
  let sandboxMode: String?
  let permissionMode: String?
  let allowBypassPermissions: Bool
  let collaborationMode: String?
  let multiAgent: Bool?
  let personality: String?
  let serviceTier: String?
  let developerInstructions: String?
  let codexConfigSource: ServerCodexConfigSource?
  let codexConfigMode: ServerCodexConfigMode?
  let codexConfigProfile: String?
  let codexModelProvider: String?
  let codexConfigOverrides: ServerCodexSessionOverrides?
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
  let isWorktree: Bool
  let worktreeId: String?
  let unreadCount: UInt64
  let displayTitle: String
  let displayTitleSortKey: String?
  let displaySearchText: String?
  let contextLine: String?
  let listStatus: ServerSessionListStatus
  let summaryRevision: UInt64

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
    case controlMode = "control_mode"
    case lifecycleState = "lifecycle_state"
    case acceptsUserInput = "accepts_user_input"
    case steerable
    case tokenUsage = "token_usage"
    case tokenUsageSnapshotKind = "token_usage_snapshot_kind"
    case hasPendingApproval = "has_pending_approval"
    case codexIntegrationMode = "codex_integration_mode"
    case claudeIntegrationMode = "claude_integration_mode"
    case approvalPolicy = "approval_policy"
    case approvalPolicyDetails = "approval_policy_details"
    case sandboxMode = "sandbox_mode"
    case permissionMode = "permission_mode"
    case allowBypassPermissions = "allow_bypass_permissions"
    case collaborationMode = "collaboration_mode"
    case multiAgent = "multi_agent"
    case personality
    case serviceTier = "service_tier"
    case developerInstructions = "developer_instructions"
    case codexConfigSource = "codex_config_source"
    case codexConfigMode = "codex_config_mode"
    case codexConfigProfile = "codex_config_profile"
    case codexModelProvider = "codex_model_provider"
    case codexConfigOverrides = "codex_config_overrides"
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
  case interrupted
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
  let controlMode: ServerSessionControlMode
  let lifecycleState: ServerSessionLifecycleState
  let acceptsUserInput: Bool
  let steerable: Bool
  let rows: [ServerConversationRowEntry]
  let totalRowCount: UInt64
  let hasMoreBefore: Bool
  let oldestSequence: UInt64?
  let newestSequence: UInt64?
  let pendingApproval: ServerApprovalRequest?
  let tokenUsage: ServerTokenUsage
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind
  let currentDiff: String?
  let cumulativeDiff: String?
  let currentPlan: String?
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let claudeIntegrationMode: ServerClaudeIntegrationMode?
  let approvalPolicy: String?
  let approvalPolicyDetails: ServerCodexApprovalPolicy?
  let sandboxMode: String?
  let permissionMode: String?
  let allowBypassPermissions: Bool
  let collaborationMode: String?
  let multiAgent: Bool?
  let personality: String?
  let serviceTier: String?
  let developerInstructions: String?
  let codexConfigSource: ServerCodexConfigSource?
  let codexConfigMode: ServerCodexConfigMode?
  let codexConfigProfile: String?
  let codexModelProvider: String?
  let codexConfigOverrides: ServerCodexSessionOverrides?
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
  let isWorktree: Bool
  let worktreeId: String?
  let unreadCount: UInt64
  let missionId: String?
  let issueIdentifier: String?

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
    case controlMode = "control_mode"
    case lifecycleState = "lifecycle_state"
    case acceptsUserInput = "accepts_user_input"
    case steerable
    case rows
    case totalRowCount = "total_row_count"
    case hasMoreBefore = "has_more_before"
    case oldestSequence = "oldest_sequence"
    case newestSequence = "newest_sequence"
    case pendingApproval = "pending_approval"
    case tokenUsage = "token_usage"
    case tokenUsageSnapshotKind = "token_usage_snapshot_kind"
    case currentDiff = "current_diff"
    case cumulativeDiff = "cumulative_diff"
    case currentPlan = "current_plan"
    case codexIntegrationMode = "codex_integration_mode"
    case claudeIntegrationMode = "claude_integration_mode"
    case approvalPolicy = "approval_policy"
    case approvalPolicyDetails = "approval_policy_details"
    case sandboxMode = "sandbox_mode"
    case permissionMode = "permission_mode"
    case allowBypassPermissions = "allow_bypass_permissions"
    case collaborationMode = "collaboration_mode"
    case multiAgent = "multi_agent"
    case personality
    case serviceTier = "service_tier"
    case developerInstructions = "developer_instructions"
    case codexConfigSource = "codex_config_source"
    case codexConfigMode = "codex_config_mode"
    case codexConfigProfile = "codex_config_profile"
    case codexModelProvider = "codex_model_provider"
    case codexConfigOverrides = "codex_config_overrides"
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
    case missionId = "mission_id"
    case issueIdentifier = "issue_identifier"
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
  let controlMode: ServerSessionControlMode?
  let lifecycleState: ServerSessionLifecycleState?
  let acceptsUserInput: Bool?
  let steerable: Bool?
  let pendingApproval: ServerApprovalRequest??
  let tokenUsage: ServerTokenUsage?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind?
  let currentDiff: String??
  let cumulativeDiff: String??
  let currentPlan: String??
  let customName: String??
  let summary: String??
  let codexIntegrationMode: ServerCodexIntegrationMode??
  let claudeIntegrationMode: ServerClaudeIntegrationMode??
  let approvalPolicy: String??
  let approvalPolicyDetails: ServerCodexApprovalPolicy??
  let sandboxMode: String??
  let collaborationMode: String??
  let multiAgent: Bool??
  let personality: String??
  let serviceTier: String??
  let developerInstructions: String??
  let codexConfigSource: ServerCodexConfigSource??
  let codexConfigMode: ServerCodexConfigMode??
  let codexConfigProfile: String??
  let codexModelProvider: String??
  let codexConfigOverrides: ServerCodexSessionOverrides??
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
    controlMode: ServerSessionControlMode? = nil,
    lifecycleState: ServerSessionLifecycleState? = nil,
    acceptsUserInput: Bool? = nil,
    steerable: Bool? = nil,
    pendingApproval: ServerApprovalRequest?? = nil,
    tokenUsage: ServerTokenUsage? = nil,
    tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind? = nil,
    currentDiff: String?? = nil,
    cumulativeDiff: String?? = nil,
    currentPlan: String?? = nil,
    customName: String?? = nil,
    summary: String?? = nil,
    codexIntegrationMode: ServerCodexIntegrationMode?? = nil,
    claudeIntegrationMode: ServerClaudeIntegrationMode?? = nil,
    approvalPolicy: String?? = nil,
    approvalPolicyDetails: ServerCodexApprovalPolicy?? = nil,
    sandboxMode: String?? = nil,
    collaborationMode: String?? = nil,
    multiAgent: Bool?? = nil,
    personality: String?? = nil,
    serviceTier: String?? = nil,
    developerInstructions: String?? = nil,
    codexConfigSource: ServerCodexConfigSource?? = nil,
    codexConfigMode: ServerCodexConfigMode?? = nil,
    codexConfigProfile: String?? = nil,
    codexModelProvider: String?? = nil,
    codexConfigOverrides: ServerCodexSessionOverrides?? = nil,
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
    self.controlMode = controlMode
    self.lifecycleState = lifecycleState
    self.acceptsUserInput = acceptsUserInput
    self.steerable = steerable
    self.pendingApproval = pendingApproval
    self.tokenUsage = tokenUsage
    self.tokenUsageSnapshotKind = tokenUsageSnapshotKind
    self.currentDiff = currentDiff
    self.cumulativeDiff = cumulativeDiff
    self.currentPlan = currentPlan
    self.customName = customName
    self.summary = summary
    self.codexIntegrationMode = codexIntegrationMode
    self.claudeIntegrationMode = claudeIntegrationMode
    self.approvalPolicy = approvalPolicy
    self.approvalPolicyDetails = approvalPolicyDetails
    self.sandboxMode = sandboxMode
    self.collaborationMode = collaborationMode
    self.multiAgent = multiAgent
    self.personality = personality
    self.serviceTier = serviceTier
    self.developerInstructions = developerInstructions
    self.codexConfigSource = codexConfigSource
    self.codexConfigMode = codexConfigMode
    self.codexConfigProfile = codexConfigProfile
    self.codexModelProvider = codexModelProvider
    self.codexConfigOverrides = codexConfigOverrides
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
    case controlMode = "control_mode"
    case lifecycleState = "lifecycle_state"
    case acceptsUserInput = "accepts_user_input"
    case steerable
    case pendingApproval = "pending_approval"
    case tokenUsage = "token_usage"
    case tokenUsageSnapshotKind = "token_usage_snapshot_kind"
    case currentDiff = "current_diff"
    case cumulativeDiff = "cumulative_diff"
    case currentPlan = "current_plan"
    case customName = "custom_name"
    case summary
    case codexIntegrationMode = "codex_integration_mode"
    case claudeIntegrationMode = "claude_integration_mode"
    case approvalPolicy = "approval_policy"
    case approvalPolicyDetails = "approval_policy_details"
    case sandboxMode = "sandbox_mode"
    case collaborationMode = "collaboration_mode"
    case multiAgent = "multi_agent"
    case personality
    case serviceTier = "service_tier"
    case developerInstructions = "developer_instructions"
    case codexConfigSource = "codex_config_source"
    case codexConfigMode = "codex_config_mode"
    case codexConfigProfile = "codex_config_profile"
    case codexModelProvider = "codex_model_provider"
    case codexConfigOverrides = "codex_config_overrides"
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
    controlMode = try container.decodeIfPresent(ServerSessionControlMode.self, forKey: .controlMode)
    lifecycleState = try container.decodeIfPresent(ServerSessionLifecycleState.self, forKey: .lifecycleState)
    acceptsUserInput = try container.decodeIfPresent(Bool.self, forKey: .acceptsUserInput)
    steerable = try container.decodeIfPresent(Bool.self, forKey: .steerable)
    pendingApproval = try container.decodePatchValue(ServerApprovalRequest.self, forKey: .pendingApproval)
    tokenUsage = try container.decodeIfPresent(ServerTokenUsage.self, forKey: .tokenUsage)
    tokenUsageSnapshotKind = try container.decodeIfPresent(
      ServerTokenUsageSnapshotKind.self,
      forKey: .tokenUsageSnapshotKind
    )
    currentDiff = try container.decodePatchValue(String.self, forKey: .currentDiff)
    cumulativeDiff = try container.decodePatchValue(String.self, forKey: .cumulativeDiff)
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
    approvalPolicyDetails = try container.decodePatchValue(
      ServerCodexApprovalPolicy.self,
      forKey: .approvalPolicyDetails
    )
    sandboxMode = try container.decodePatchValue(String.self, forKey: .sandboxMode)
    collaborationMode = try container.decodePatchValue(String.self, forKey: .collaborationMode)
    multiAgent = try container.decodePatchValue(Bool.self, forKey: .multiAgent)
    personality = try container.decodePatchValue(String.self, forKey: .personality)
    serviceTier = try container.decodePatchValue(String.self, forKey: .serviceTier)
    developerInstructions = try container.decodePatchValue(String.self, forKey: .developerInstructions)
    codexConfigSource = try container.decodePatchValue(ServerCodexConfigSource.self, forKey: .codexConfigSource)
    codexConfigMode = try container.decodePatchValue(ServerCodexConfigMode.self, forKey: .codexConfigMode)
    codexConfigProfile = try container.decodePatchValue(String.self, forKey: .codexConfigProfile)
    codexModelProvider = try container.decodePatchValue(String.self, forKey: .codexModelProvider)
    codexConfigOverrides = try container.decodePatchValue(
      ServerCodexSessionOverrides.self,
      forKey: .codexConfigOverrides
    )
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
