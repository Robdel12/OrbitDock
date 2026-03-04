//
//  ServerProtocol.swift
//  OrbitDock
//
//  Protocol types for communication with OrbitDock Rust server.
//  These mirror the types in orbitdock-protocol crate.
//

import Foundation

// MARK: - Provider

enum ServerProvider: String, Codable {
  case claude
  case codex
}

enum ServerCodexIntegrationMode: String, Codable {
  case direct
  case passive
}

enum ServerClaudeIntegrationMode: String, Codable {
  case direct
  case passive
}

// MARK: - Worktree Types

enum ServerWorktreeStatus: String, Codable {
  case active
  case orphaned
  case stale
  case removing
  case removed
}

enum ServerWorktreeOrigin: String, Codable {
  case user
  case agent
  case discovered
}

struct ServerWorktreeSummary: Codable, Identifiable {
  var id: String
  var repoRoot: String
  var worktreePath: String
  var branch: String
  var baseBranch: String?
  var status: ServerWorktreeStatus
  var activeSessionCount: UInt32
  var totalSessionCount: UInt32
  var createdAt: String
  var lastSessionEndedAt: String?
  var diskPresent: Bool
  var autoPrune: Bool
  var customName: String?
  var createdBy: ServerWorktreeOrigin

  enum CodingKeys: String, CodingKey {
    case id, branch, status
    case repoRoot = "repo_root"
    case worktreePath = "worktree_path"
    case baseBranch = "base_branch"
    case activeSessionCount = "active_session_count"
    case totalSessionCount = "total_session_count"
    case createdAt = "created_at"
    case lastSessionEndedAt = "last_session_ended_at"
    case diskPresent = "disk_present"
    case autoPrune = "auto_prune"
    case customName = "custom_name"
    case createdBy = "created_by"
  }
}

enum ServerTokenUsageSnapshotKind: String, Codable, Hashable, Sendable {
  case unknown
  case contextTurn = "context_turn"
  case lifetimeTotals = "lifetime_totals"
  case mixedLegacy = "mixed_legacy"
  case compactionReset = "compaction_reset"
}

enum ServerShellExecutionOutcome: String, Codable {
  case completed
  case failed
  case timedOut = "timed_out"
  case canceled
}

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

// MARK: - Message Types

enum ServerMessageType: String, Codable {
  case user
  case assistant
  case thinking
  case tool
  case toolResult = "tool_result"
  case steer
  case shell
}

// MARK: - Core Types

struct ServerMessage: Codable, Identifiable {
  let id: String
  let sessionId: String
  let type: ServerMessageType
  let content: String
  let toolName: String?
  let toolInput: String? // JSON string
  let toolOutput: String?
  let isError: Bool
  let isInProgress: Bool
  let timestamp: String
  let durationMs: UInt64?
  let images: [ServerImageInput]

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case type = "message_type"
    case content
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case toolOutput = "tool_output"
    case isError = "is_error"
    case isInProgress = "is_in_progress"
    case timestamp
    case durationMs = "duration_ms"
    case images
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    type = try container.decode(ServerMessageType.self, forKey: .type)
    content = try container.decode(String.self, forKey: .content)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    toolInput = try container.decodeIfPresent(String.self, forKey: .toolInput)
    toolOutput = try container.decodeIfPresent(String.self, forKey: .toolOutput)
    isError = try container.decode(Bool.self, forKey: .isError)
    isInProgress = try container.decodeIfPresent(Bool.self, forKey: .isInProgress) ?? false
    timestamp = try container.decode(String.self, forKey: .timestamp)
    durationMs = try container.decodeIfPresent(UInt64.self, forKey: .durationMs)
    images = try container.decodeIfPresent([ServerImageInput].self, forKey: .images) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(type, forKey: .type)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(toolName, forKey: .toolName)
    try container.encodeIfPresent(toolInput, forKey: .toolInput)
    try container.encodeIfPresent(toolOutput, forKey: .toolOutput)
    try container.encode(isError, forKey: .isError)
    if isInProgress {
      try container.encode(isInProgress, forKey: .isInProgress)
    }
    try container.encode(timestamp, forKey: .timestamp)
    try container.encodeIfPresent(durationMs, forKey: .durationMs)
    if !images.isEmpty {
      try container.encode(images, forKey: .images)
    }
  }

  /// Parse toolInput JSON string to dictionary if needed
  var toolInputDict: [String: Any]? {
    guard let json = toolInput,
          let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return dict
  }
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

enum ServerApprovalPreviewType: String, Codable {
  case shellCommand = "shell_command"
  case diff
  case url
  case searchQuery = "search_query"
  case pattern
  case prompt
  case value
  case filePath = "file_path"
  case action
}

enum ServerApprovalRiskLevel: String, Codable {
  case low
  case normal
  case high
}

struct ServerApprovalPreviewSegment: Codable, Hashable {
  let command: String
  let leadingOperator: String?

  enum CodingKeys: String, CodingKey {
    case command
    case leadingOperator = "leading_operator"
  }
}

struct ServerApprovalPreview: Codable, Hashable {
  let type: ServerApprovalPreviewType
  let value: String
  let shellSegments: [ServerApprovalPreviewSegment]
  let compact: String?
  let decisionScope: String?
  let riskLevel: ServerApprovalRiskLevel?
  let riskFindings: [String]
  let manifest: String?

  enum CodingKeys: String, CodingKey {
    case type
    case value
    case shellSegments = "shell_segments"
    case compact
    case decisionScope = "decision_scope"
    case riskLevel = "risk_level"
    case riskFindings = "risk_findings"
    case manifest
  }

  init(
    type: ServerApprovalPreviewType,
    value: String,
    shellSegments: [ServerApprovalPreviewSegment] = [],
    compact: String? = nil,
    decisionScope: String? = nil,
    riskLevel: ServerApprovalRiskLevel? = nil,
    riskFindings: [String] = [],
    manifest: String? = nil
  ) {
    self.type = type
    self.value = value
    self.shellSegments = shellSegments
    self.compact = compact
    self.decisionScope = decisionScope
    self.riskLevel = riskLevel
    self.riskFindings = riskFindings
    self.manifest = manifest
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(ServerApprovalPreviewType.self, forKey: .type)
    value = try container.decode(String.self, forKey: .value)
    shellSegments = try container.decodeIfPresent([ServerApprovalPreviewSegment].self, forKey: .shellSegments) ?? []
    compact = try container.decodeIfPresent(String.self, forKey: .compact)
    decisionScope = try container.decodeIfPresent(String.self, forKey: .decisionScope)
    riskLevel = try container.decodeIfPresent(ServerApprovalRiskLevel.self, forKey: .riskLevel)
    riskFindings = try container.decodeIfPresent([String].self, forKey: .riskFindings) ?? []
    manifest = try container.decodeIfPresent(String.self, forKey: .manifest)
  }
}

struct ServerApprovalQuestionOption: Codable, Hashable {
  let label: String
  let description: String?

  enum CodingKeys: String, CodingKey {
    case label
    case description
  }
}

struct ServerApprovalQuestionPrompt: Codable, Hashable {
  let id: String
  let header: String?
  let question: String
  let options: [ServerApprovalQuestionOption]
  let allowsMultipleSelection: Bool
  let allowsOther: Bool
  let isSecret: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case header
    case question
    case options
    case allowsMultipleSelection = "allows_multiple_selection"
    case allowsOther = "allows_other"
    case isSecret = "is_secret"
  }

  init(
    id: String,
    header: String? = nil,
    question: String,
    options: [ServerApprovalQuestionOption] = [],
    allowsMultipleSelection: Bool = false,
    allowsOther: Bool = false,
    isSecret: Bool = false
  ) {
    self.id = id
    self.header = header
    self.question = question
    self.options = options
    self.allowsMultipleSelection = allowsMultipleSelection
    self.allowsOther = allowsOther
    self.isSecret = isSecret
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    header = try container.decodeIfPresent(String.self, forKey: .header)
    question = try container.decode(String.self, forKey: .question)
    options = try container.decodeIfPresent([ServerApprovalQuestionOption].self, forKey: .options) ?? []
    allowsMultipleSelection = try container.decodeIfPresent(Bool.self, forKey: .allowsMultipleSelection) ?? false
    allowsOther = try container.decodeIfPresent(Bool.self, forKey: .allowsOther) ?? false
    isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
  }
}

struct ServerApprovalRequest: Codable, Identifiable {
  let id: String
  let sessionId: String
  let type: ServerApprovalType
  let toolName: String?
  let toolInput: String?
  let command: String?
  let filePath: String?
  let diff: String?
  let question: String?
  let questionPrompts: [ServerApprovalQuestionPrompt]
  let preview: ServerApprovalPreview?
  let proposedAmendment: [String]?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case type
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case command
    case filePath = "file_path"
    case diff
    case question
    case questionPrompts = "question_prompts"
    case preview
    case proposedAmendment = "proposed_amendment"
  }

  init(
    id: String,
    sessionId: String,
    type: ServerApprovalType,
    toolName: String? = nil,
    toolInput: String? = nil,
    command: String? = nil,
    filePath: String? = nil,
    diff: String? = nil,
    question: String? = nil,
    questionPrompts: [ServerApprovalQuestionPrompt] = [],
    preview: ServerApprovalPreview? = nil,
    proposedAmendment: [String]? = nil
  ) {
    self.id = id
    self.sessionId = sessionId
    self.type = type
    self.toolName = toolName
    self.toolInput = toolInput
    self.command = command
    self.filePath = filePath
    self.diff = diff
    self.question = question
    self.questionPrompts = questionPrompts
    self.preview = preview
    self.proposedAmendment = proposedAmendment
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    type = try container.decode(ServerApprovalType.self, forKey: .type)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    toolInput = try container.decodeIfPresent(String.self, forKey: .toolInput)
    command = try container.decodeIfPresent(String.self, forKey: .command)
    filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
    diff = try container.decodeIfPresent(String.self, forKey: .diff)
    question = try container.decodeIfPresent(String.self, forKey: .question)
    questionPrompts =
      try container.decodeIfPresent([ServerApprovalQuestionPrompt].self, forKey: .questionPrompts) ?? []
    preview = try container.decodeIfPresent(ServerApprovalPreview.self, forKey: .preview)
    proposedAmendment = try container.decodeIfPresent([String].self, forKey: .proposedAmendment)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(type, forKey: .type)
    try container.encodeIfPresent(toolName, forKey: .toolName)
    try container.encodeIfPresent(toolInput, forKey: .toolInput)
    try container.encodeIfPresent(command, forKey: .command)
    try container.encodeIfPresent(filePath, forKey: .filePath)
    try container.encodeIfPresent(diff, forKey: .diff)
    try container.encodeIfPresent(question, forKey: .question)
    if !questionPrompts.isEmpty {
      try container.encode(questionPrompts, forKey: .questionPrompts)
    }
    try container.encodeIfPresent(preview, forKey: .preview)
    try container.encodeIfPresent(proposedAmendment, forKey: .proposedAmendment)
  }
}

enum ServerApprovalType: String, Codable {
  case exec
  case patch
  case question
}

struct ServerApprovalHistoryItem: Codable, Identifiable {
  let id: Int64
  let sessionId: String
  let requestId: String
  let approvalType: ServerApprovalType
  let toolName: String?
  let command: String?
  let filePath: String?
  let cwd: String?
  let decision: String?
  let proposedAmendment: [String]?
  let createdAt: String
  let decidedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case requestId = "request_id"
    case approvalType = "approval_type"
    case toolName = "tool_name"
    case command
    case filePath = "file_path"
    case cwd
    case decision
    case proposedAmendment = "proposed_amendment"
    case createdAt = "created_at"
    case decidedAt = "decided_at"
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

// MARK: - Review Comments

enum ServerReviewCommentTag: String, Codable {
  case clarity
  case scope
  case risk
  case nit
}

enum ServerReviewCommentStatus: String, Codable {
  case open
  case resolved
}

struct ServerReviewComment: Codable, Identifiable {
  let id: String
  let sessionId: String
  let turnId: String?
  let filePath: String
  let lineStart: UInt32
  let lineEnd: UInt32?
  let body: String
  let tag: ServerReviewCommentTag?
  let status: ServerReviewCommentStatus
  let createdAt: String
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case turnId = "turn_id"
    case filePath = "file_path"
    case lineStart = "line_start"
    case lineEnd = "line_end"
    case body
    case tag
    case status
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

// MARK: - Subagent Types

struct ServerSubagentInfo: Codable, Identifiable {
  let id: String
  let agentType: String
  let startedAt: String
  let endedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case agentType = "agent_type"
    case startedAt = "started_at"
    case endedAt = "ended_at"
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
}

struct ServerMessageChanges: Codable {
  let content: String?
  let toolOutput: String?
  let isError: Bool?
  let isInProgress: Bool?
  let durationMs: UInt64?

  enum CodingKeys: String, CodingKey {
    case content
    case toolOutput = "tool_output"
    case isError = "is_error"
    case isInProgress = "is_in_progress"
    case durationMs = "duration_ms"
  }
}

// MARK: - Codex Models

struct ServerCodexModelOption: Codable, Identifiable {
  let id: String
  let model: String
  let displayName: String
  let description: String
  let isDefault: Bool
  let supportedReasoningEfforts: [String]
  var supportsReasoningSummaries: Bool? = nil

  enum CodingKeys: String, CodingKey {
    case id
    case model
    case displayName = "display_name"
    case description
    case isDefault = "is_default"
    case supportedReasoningEfforts = "supported_reasoning_efforts"
    case supportsReasoningSummaries = "supports_reasoning_summaries"
  }
}

// MARK: - Claude Models

struct ServerClaudeModelOption: Codable, Identifiable {
  var id: String {
    value
  }

  let value: String
  let displayName: String
  let description: String

  enum CodingKeys: String, CodingKey {
    case value
    case displayName = "display_name"
    case description
  }
}

// MARK: - Codex Account Auth

enum ServerCodexAuthMode: String, Codable {
  case apiKey = "api_key"
  case chatgpt
}

enum ServerCodexAccount: Codable {
  case apiKey
  case chatgpt(email: String?, planType: String?)

  enum CodingKeys: String, CodingKey {
    case type
    case email
    case planType = "plan_type"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
      case "api_key":
        self = .apiKey
      case "chatgpt":
        self = try .chatgpt(
          email: container.decodeIfPresent(String.self, forKey: .email),
          planType: container.decodeIfPresent(String.self, forKey: .planType)
        )
      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Unknown codex account type: \(type)"
          )
        )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case .apiKey:
        try container.encode("api_key", forKey: .type)
      case let .chatgpt(email, planType):
        try container.encode("chatgpt", forKey: .type)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(planType, forKey: .planType)
    }
  }
}

enum ServerCodexLoginCancelStatus: String, Codable {
  case canceled
  case notFound = "not_found"
  case invalidId = "invalid_id"
}

struct ServerCodexAccountStatus: Codable {
  let authMode: ServerCodexAuthMode?
  let requiresOpenaiAuth: Bool
  let account: ServerCodexAccount?
  let loginInProgress: Bool
  let activeLoginId: String?

  enum CodingKeys: String, CodingKey {
    case authMode = "auth_mode"
    case requiresOpenaiAuth = "requires_openai_auth"
    case account
    case loginInProgress = "login_in_progress"
    case activeLoginId = "active_login_id"
  }
}

// MARK: - Skills

struct ServerSkillInput: Codable {
  let name: String
  let path: String
}

// MARK: - Images

struct ServerImageInput: Codable {
  let inputType: String
  let value: String

  enum CodingKeys: String, CodingKey {
    case inputType = "input_type"
    case value
  }
}

// MARK: - Mentions

struct ServerMentionInput: Codable {
  let name: String
  let path: String
}

enum ServerSkillScope: String, Codable {
  case user, repo, system, admin
}

struct ServerSkillMetadata: Codable, Identifiable {
  let name: String
  let description: String
  let shortDescription: String?
  let path: String
  let scope: ServerSkillScope
  let enabled: Bool

  var id: String {
    path
  }

  enum CodingKeys: String, CodingKey {
    case name, description, path, scope, enabled
    case shortDescription = "short_description"
  }
}

struct ServerSkillErrorInfo: Codable {
  let path: String
  let message: String
}

struct ServerSkillsListEntry: Codable {
  let cwd: String
  let skills: [ServerSkillMetadata]
  let errors: [ServerSkillErrorInfo]
}

struct ServerRemoteSkillSummary: Codable, Identifiable {
  let id: String
  let name: String
  let description: String
}

// MARK: - MCP Types

struct ServerMcpTool: Codable {
  let name: String
  let title: String?
  let description: String?
  let inputSchema: AnyCodable
  let outputSchema: AnyCodable?
  let annotations: AnyCodable?

  enum CodingKeys: String, CodingKey {
    case name, title, description, annotations
    case inputSchema
    case outputSchema
  }
}

struct ServerMcpResource: Codable {
  let name: String
  let uri: String
  let description: String?
  let mimeType: String?
  let title: String?
  let size: Int64?
  let annotations: AnyCodable?

  enum CodingKeys: String, CodingKey {
    case name, uri, description, title, size, annotations
    case mimeType
  }
}

struct ServerMcpResourceTemplate: Codable {
  let name: String
  let uriTemplate: String
  let title: String?
  let description: String?
  let mimeType: String?
  let annotations: AnyCodable?

  enum CodingKeys: String, CodingKey {
    case name, title, description, annotations
    case uriTemplate
    case mimeType
  }
}

enum ServerMcpAuthStatus: String, Codable {
  case unsupported
  case notLoggedIn = "not_logged_in"
  case bearerToken = "bearer_token"
  case oauth
}

/// Tagged enum matching Rust's `#[serde(tag = "state", rename_all = "snake_case")]`
enum ServerMcpStartupStatus: Codable {
  case starting
  case connecting
  case ready
  case failed(error: String)
  case needsAuth
  case cancelled

  enum CodingKeys: String, CodingKey {
    case state
    case error
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state = try container.decode(String.self, forKey: .state)
    switch state {
      case "starting": self = .starting
      case "connecting": self = .connecting
      case "ready": self = .ready
      case "failed":
        let error = try container.decode(String.self, forKey: .error)
        self = .failed(error: error)
      case "needs_auth": self = .needsAuth
      case "cancelled": self = .cancelled
      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Unknown MCP startup state: \(state)"
          )
        )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case .starting:
        try container.encode("starting", forKey: .state)
      case .connecting:
        try container.encode("connecting", forKey: .state)
      case .ready:
        try container.encode("ready", forKey: .state)
      case let .failed(error):
        try container.encode("failed", forKey: .state)
        try container.encode(error, forKey: .error)
      case .needsAuth:
        try container.encode("needs_auth", forKey: .state)
      case .cancelled:
        try container.encode("cancelled", forKey: .state)
    }
  }
}

struct ServerMcpStartupFailure: Codable {
  let server: String
  let error: String
}

// MARK: - Rate Limit Info

struct ServerRateLimitInfo: Codable {
  let status: String
  let resetsAt: String?
  let rateLimitType: String?
  let utilization: Double?
  let isUsingOverage: Bool?
  let overageStatus: String?
  let surpassedThreshold: Double?

  enum CodingKeys: String, CodingKey {
    case status
    case resetsAt = "resets_at"
    case rateLimitType = "rate_limit_type"
    case utilization
    case isUsingOverage = "is_using_overage"
    case overageStatus = "overage_status"
    case surpassedThreshold = "surpassed_threshold"
  }

  var isWarning: Bool {
    status == "allowed_warning"
  }

  var isRejected: Bool {
    status == "rejected"
  }

  var needsDisplay: Bool {
    status != "allowed"
  }
}

/// Wrapper for arbitrary JSON values (used for MCP schemas/annotations)
struct AnyCodable: Codable {
  let value: Any

  init(_ value: Any) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let dict = try? container.decode([String: AnyCodable].self) {
      value = dict.mapValues { $0.value }
    } else if let array = try? container.decode([AnyCodable].self) {
      value = array.map(\.value)
    } else if let string = try? container.decode(String.self) {
      value = string
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let double = try? container.decode(Double.self) {
      value = double
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if container.decodeNil() {
      value = NSNull()
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
      case let dict as [String: Any]:
        try container.encode(dict.mapValues { AnyCodable($0) })
      case let array as [Any]:
        try container.encode(array.map { AnyCodable($0) })
      case let string as String:
        try container.encode(string)
      case let int as Int:
        try container.encode(int)
      case let double as Double:
        try container.encode(double)
      case let bool as Bool:
        try container.encode(bool)
      case is NSNull:
        try container.encodeNil()
      default:
        try container.encodeNil()
    }
  }
}

// MARK: - Remote Filesystem Browsing

struct ServerDirectoryEntry: Codable, Identifiable {
  let name: String
  let isDir: Bool
  let isGit: Bool

  var id: String {
    name
  }

  enum CodingKeys: String, CodingKey {
    case name
    case isDir = "is_dir"
    case isGit = "is_git"
  }
}

struct ServerRecentProject: Codable, Identifiable {
  let path: String
  let sessionCount: UInt32
  let lastActive: String?

  var id: String {
    path
  }

  enum CodingKeys: String, CodingKey {
    case path
    case sessionCount = "session_count"
    case lastActive = "last_active"
  }
}

struct ServerUsageErrorInfo: Codable {
  let code: String
  let message: String
}

struct ServerClientPrimaryClaim: Codable, Equatable, Identifiable {
  let clientId: String
  let deviceName: String

  var id: String {
    clientId
  }

  enum CodingKeys: String, CodingKey {
    case clientId = "client_id"
    case deviceName = "device_name"
  }
}

struct ServerCodexRateLimitWindow: Codable {
  let usedPercent: Double
  let windowDurationMins: UInt32
  let resetsAtUnix: Double

  enum CodingKeys: String, CodingKey {
    case usedPercent = "used_percent"
    case windowDurationMins = "window_duration_mins"
    case resetsAtUnix = "resets_at_unix"
  }
}

struct ServerCodexUsageSnapshot: Codable {
  let primary: ServerCodexRateLimitWindow?
  let secondary: ServerCodexRateLimitWindow?
  let fetchedAtUnix: Double

  enum CodingKeys: String, CodingKey {
    case primary
    case secondary
    case fetchedAtUnix = "fetched_at_unix"
  }
}

struct ServerClaudeUsageWindow: Codable {
  let utilization: Double
  let resetsAt: String?

  enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }
}

struct ServerClaudeUsageSnapshot: Codable {
  let fiveHour: ServerClaudeUsageWindow
  let sevenDay: ServerClaudeUsageWindow?
  let sevenDaySonnet: ServerClaudeUsageWindow?
  let sevenDayOpus: ServerClaudeUsageWindow?
  let rateLimitTier: String?
  let fetchedAtUnix: Double

  enum CodingKeys: String, CodingKey {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case sevenDaySonnet = "seven_day_sonnet"
    case sevenDayOpus = "seven_day_opus"
    case rateLimitTier = "rate_limit_tier"
    case fetchedAtUnix = "fetched_at_unix"
  }
}

// MARK: - Server → Client Messages

enum ServerToClientMessage: Codable {
  case sessionsList(sessions: [ServerSessionSummary])
  case sessionSnapshot(session: ServerSessionState)
  case sessionDelta(sessionId: String, changes: ServerStateChanges)
  case messageAppended(sessionId: String, message: ServerMessage)
  case messageUpdated(sessionId: String, messageId: String, changes: ServerMessageChanges)
  case approvalRequested(sessionId: String, request: ServerApprovalRequest, approvalVersion: UInt64?)
  case tokensUpdated(sessionId: String, usage: ServerTokenUsage, snapshotKind: ServerTokenUsageSnapshotKind)
  case sessionCreated(session: ServerSessionSummary)
  case sessionEnded(sessionId: String, reason: String)
  case approvalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem])
  case approvalDeleted(approvalId: Int64)
  case modelsList(models: [ServerCodexModelOption])
  case codexAccountStatus(status: ServerCodexAccountStatus)
  case codexLoginChatgptStarted(loginId: String, authUrl: String)
  case codexLoginChatgptCompleted(loginId: String, success: Bool, error: String?)
  case codexLoginChatgptCanceled(loginId: String, status: ServerCodexLoginCancelStatus)
  case codexAccountUpdated(status: ServerCodexAccountStatus)
  case skillsList(sessionId: String, skills: [ServerSkillsListEntry], errors: [ServerSkillErrorInfo])
  case remoteSkillsList(sessionId: String, skills: [ServerRemoteSkillSummary])
  case remoteSkillDownloaded(sessionId: String, skillId: String, name: String, path: String)
  case skillsUpdateAvailable(sessionId: String)
  case mcpToolsList(
    sessionId: String,
    tools: [String: ServerMcpTool],
    resources: [String: [ServerMcpResource]],
    resourceTemplates: [String: [ServerMcpResourceTemplate]],
    authStatuses: [String: ServerMcpAuthStatus]
  )
  case mcpStartupUpdate(sessionId: String, server: String, status: ServerMcpStartupStatus)
  case mcpStartupComplete(sessionId: String, ready: [String], failed: [ServerMcpStartupFailure], cancelled: [String])
  case claudeCapabilities(
    sessionId: String,
    slashCommands: [String],
    skills: [String],
    tools: [String],
    models: [ServerClaudeModelOption]
  )
  case claudeModelsList(models: [ServerClaudeModelOption])
  case contextCompacted(sessionId: String)
  case undoStarted(sessionId: String, message: String?)
  case undoCompleted(sessionId: String, success: Bool, message: String?)
  case threadRolledBack(sessionId: String, numTurns: UInt32)
  case sessionForked(sourceSessionId: String, newSessionId: String, forkedFromThreadId: String?)
  case turnDiffSnapshot(
    sessionId: String,
    turnId: String,
    diff: String,
    inputTokens: UInt64?,
    outputTokens: UInt64?,
    cachedTokens: UInt64?,
    contextWindow: UInt64?,
    snapshotKind: ServerTokenUsageSnapshotKind
  )
  case reviewCommentCreated(sessionId: String, comment: ServerReviewComment)
  case reviewCommentUpdated(sessionId: String, comment: ServerReviewComment)
  case reviewCommentDeleted(sessionId: String, commentId: String)
  case reviewCommentsList(sessionId: String, comments: [ServerReviewComment])
  case subagentToolsList(sessionId: String, subagentId: String, tools: [ServerSubagentTool])
  case shellStarted(sessionId: String, requestId: String, command: String)
  case shellOutput(
    sessionId: String,
    requestId: String,
    stdout: String,
    stderr: String,
    exitCode: Int32?,
    durationMs: UInt64,
    outcome: ServerShellExecutionOutcome
  )
  case directoryListing(requestId: String, path: String, entries: [ServerDirectoryEntry])
  case recentProjectsList(requestId: String, projects: [ServerRecentProject])
  case codexUsageResult(requestId: String, usage: ServerCodexUsageSnapshot?, errorInfo: ServerUsageErrorInfo?)
  case claudeUsageResult(requestId: String, usage: ServerClaudeUsageSnapshot?, errorInfo: ServerUsageErrorInfo?)
  case openAiKeyStatus(requestId: String, configured: Bool)
  case serverInfo(isPrimary: Bool, clientPrimaryClaims: [ServerClientPrimaryClaim])
  case approvalDecisionResult(
    sessionId: String,
    requestId: String,
    outcome: String,
    activeRequestId: String?,
    approvalVersion: UInt64
  )
  case worktreesList(requestId: String, repoRoot: String?, worktrees: [ServerWorktreeSummary])
  case worktreeCreated(requestId: String, worktree: ServerWorktreeSummary)
  case worktreeRemoved(requestId: String, worktreeId: String)
  case worktreeStatusChanged(worktreeId: String, status: ServerWorktreeStatus, repoRoot: String)
  case worktreeError(requestId: String, code: String, message: String)
  case rateLimitEvent(sessionId: String, info: ServerRateLimitInfo)
  case promptSuggestion(sessionId: String, suggestion: String)
  case filesPersisted(sessionId: String, files: [String])
  case error(code: String, message: String, sessionId: String?)

  enum CodingKeys: String, CodingKey {
    case type
    case sessions
    case session
    case sessionId = "session_id"
    case changes
    case message
    case messageId = "message_id"
    case request
    case usage
    case reason
    case code
    case error
    case errorInfo = "error_info"
    case approvals
    case approvalId = "approval_id"
    case models
    case loginId = "login_id"
    case authUrl = "auth_url"
    case skills
    case errors
    case id
    case name
    case path
    case success
    case numTurns = "num_turns"
    case tools
    case resources
    case resourceTemplates = "resource_templates"
    case authStatuses = "auth_statuses"
    case server
    case status
    case ready
    case failed
    case cancelled
    case sourceSessionId = "source_session_id"
    case newSessionId = "new_session_id"
    case forkedFromThreadId = "forked_from_thread_id"
    case turnId = "turn_id"
    case diff
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cachedTokens = "cached_tokens"
    case contextWindow = "context_window"
    case snapshotKind = "snapshot_kind"
    case comment
    case commentId = "comment_id"
    case comments
    case subagentId = "subagent_id"
    case requestId = "request_id"
    case command
    case stdout
    case stderr
    case exitCode = "exit_code"
    case durationMs = "duration_ms"
    case slashCommands = "slash_commands"
    case entries
    case projects
    case configured
    case isPrimary = "is_primary"
    case clientPrimaryClaims = "client_primary_claims"
    case approvalVersion = "approval_version"
    case outcome
    case activeRequestId = "active_request_id"
    case worktrees
    case worktree
    case worktreeId = "worktree_id"
    case repoRoot = "repo_root"
    case force
    case info
    case suggestion
    case files
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
      case "sessions_list":
        let sessions = try container.decode([ServerSessionSummary].self, forKey: .sessions)
        self = .sessionsList(sessions: sessions)

      case "session_snapshot":
        let session = try container.decode(ServerSessionState.self, forKey: .session)
        self = .sessionSnapshot(session: session)

      case "session_delta":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let changes = try container.decode(ServerStateChanges.self, forKey: .changes)
        self = .sessionDelta(sessionId: sessionId, changes: changes)

      case "message_appended":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let message = try container.decode(ServerMessage.self, forKey: .message)
        self = .messageAppended(sessionId: sessionId, message: message)

      case "message_updated":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let messageId = try container.decode(String.self, forKey: .messageId)
        let changes = try container.decode(ServerMessageChanges.self, forKey: .changes)
        self = .messageUpdated(sessionId: sessionId, messageId: messageId, changes: changes)

      case "approval_requested":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let request = try container.decode(ServerApprovalRequest.self, forKey: .request)
        let approvalVersion = try container.decodeIfPresent(UInt64.self, forKey: .approvalVersion)
        self = .approvalRequested(sessionId: sessionId, request: request, approvalVersion: approvalVersion)

      case "tokens_updated":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let usage = try container.decode(ServerTokenUsage.self, forKey: .usage)
        let snapshotKind =
          try container.decodeIfPresent(ServerTokenUsageSnapshotKind.self, forKey: .snapshotKind) ?? .unknown
        self = .tokensUpdated(sessionId: sessionId, usage: usage, snapshotKind: snapshotKind)

      case "session_created":
        let session = try container.decode(ServerSessionSummary.self, forKey: .session)
        self = .sessionCreated(session: session)

      case "session_ended":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let reason = try container.decode(String.self, forKey: .reason)
        self = .sessionEnded(sessionId: sessionId, reason: reason)

      case "approvals_list":
        let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        let approvals = try container.decode([ServerApprovalHistoryItem].self, forKey: .approvals)
        self = .approvalsList(sessionId: sessionId, approvals: approvals)

      case "approval_deleted":
        let approvalId = try container.decode(Int64.self, forKey: .approvalId)
        self = .approvalDeleted(approvalId: approvalId)

      case "models_list":
        let models = try container.decode([ServerCodexModelOption].self, forKey: .models)
        self = .modelsList(models: models)

      case "codex_account_status":
        let status = try container.decode(ServerCodexAccountStatus.self, forKey: .status)
        self = .codexAccountStatus(status: status)

      case "codex_login_chatgpt_started":
        let loginId = try container.decode(String.self, forKey: .loginId)
        let authUrl = try container.decode(String.self, forKey: .authUrl)
        self = .codexLoginChatgptStarted(loginId: loginId, authUrl: authUrl)

      case "codex_login_chatgpt_completed":
        let loginId = try container.decode(String.self, forKey: .loginId)
        let success = try container.decode(Bool.self, forKey: .success)
        let error = try container.decodeIfPresent(String.self, forKey: .error)
        self = .codexLoginChatgptCompleted(loginId: loginId, success: success, error: error)

      case "codex_login_chatgpt_canceled":
        let loginId = try container.decode(String.self, forKey: .loginId)
        let status = try container.decode(ServerCodexLoginCancelStatus.self, forKey: .status)
        self = .codexLoginChatgptCanceled(loginId: loginId, status: status)

      case "codex_account_updated":
        let status = try container.decode(ServerCodexAccountStatus.self, forKey: .status)
        self = .codexAccountUpdated(status: status)

      case "skills_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let skills = try container.decode([ServerSkillsListEntry].self, forKey: .skills)
        let errors = try container.decodeIfPresent([ServerSkillErrorInfo].self, forKey: .errors) ?? []
        self = .skillsList(sessionId: sessionId, skills: skills, errors: errors)

      case "remote_skills_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let skills = try container.decode([ServerRemoteSkillSummary].self, forKey: .skills)
        self = .remoteSkillsList(sessionId: sessionId, skills: skills)

      case "remote_skill_downloaded":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let path = try container.decode(String.self, forKey: .path)
        self = .remoteSkillDownloaded(sessionId: sessionId, skillId: id, name: name, path: path)

      case "skills_update_available":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        self = .skillsUpdateAvailable(sessionId: sessionId)

      case "mcp_tools_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let tools = try container.decode([String: ServerMcpTool].self, forKey: .tools)
        let resources = try container.decode([String: [ServerMcpResource]].self, forKey: .resources)
        let resourceTemplates = try container.decode(
          [String: [ServerMcpResourceTemplate]].self,
          forKey: .resourceTemplates
        )
        let authStatuses = try container.decode([String: ServerMcpAuthStatus].self, forKey: .authStatuses)
        self = .mcpToolsList(
          sessionId: sessionId,
          tools: tools,
          resources: resources,
          resourceTemplates: resourceTemplates,
          authStatuses: authStatuses
        )

      case "mcp_startup_update":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let server = try container.decode(String.self, forKey: .server)
        let status = try container.decode(ServerMcpStartupStatus.self, forKey: .status)
        self = .mcpStartupUpdate(sessionId: sessionId, server: server, status: status)

      case "mcp_startup_complete":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let ready = try container.decode([String].self, forKey: .ready)
        let failed = try container.decode([ServerMcpStartupFailure].self, forKey: .failed)
        let cancelled = try container.decode([String].self, forKey: .cancelled)
        self = .mcpStartupComplete(sessionId: sessionId, ready: ready, failed: failed, cancelled: cancelled)

      case "claude_capabilities":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let slashCommands = try container.decodeIfPresent([String].self, forKey: .slashCommands) ?? []
        let skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        let tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        let models = try container.decodeIfPresent([ServerClaudeModelOption].self, forKey: .models) ?? []
        self = .claudeCapabilities(
          sessionId: sessionId,
          slashCommands: slashCommands,
          skills: skills,
          tools: tools,
          models: models
        )

      case "claude_models_list":
        let models = try container.decode([ServerClaudeModelOption].self, forKey: .models)
        self = .claudeModelsList(models: models)

      case "context_compacted":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        self = .contextCompacted(sessionId: sessionId)

      case "undo_started":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        self = .undoStarted(sessionId: sessionId, message: message)

      case "undo_completed":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let success = try container.decode(Bool.self, forKey: .success)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        self = .undoCompleted(sessionId: sessionId, success: success, message: message)

      case "thread_rolled_back":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let numTurns = try container.decode(UInt32.self, forKey: .numTurns)
        self = .threadRolledBack(sessionId: sessionId, numTurns: numTurns)

      case "session_forked":
        let sourceSessionId = try container.decode(String.self, forKey: .sourceSessionId)
        let newSessionId = try container.decode(String.self, forKey: .newSessionId)
        let forkedFromThreadId = try container.decodeIfPresent(String.self, forKey: .forkedFromThreadId)
        self = .sessionForked(
          sourceSessionId: sourceSessionId,
          newSessionId: newSessionId,
          forkedFromThreadId: forkedFromThreadId
        )

      case "turn_diff_snapshot":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let turnId = try container.decode(String.self, forKey: .turnId)
        let diff = try container.decode(String.self, forKey: .diff)
        let inputTokens = try container.decodeIfPresent(UInt64.self, forKey: .inputTokens)
        let outputTokens = try container.decodeIfPresent(UInt64.self, forKey: .outputTokens)
        let cachedTokens = try container.decodeIfPresent(UInt64.self, forKey: .cachedTokens)
        let contextWindow = try container.decodeIfPresent(UInt64.self, forKey: .contextWindow)
        let snapshotKind =
          try container.decodeIfPresent(ServerTokenUsageSnapshotKind.self, forKey: .snapshotKind) ?? .unknown
        self = .turnDiffSnapshot(
          sessionId: sessionId,
          turnId: turnId,
          diff: diff,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cachedTokens: cachedTokens,
          contextWindow: contextWindow,
          snapshotKind: snapshotKind
        )

      case "review_comment_created":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let comment = try container.decode(ServerReviewComment.self, forKey: .comment)
        self = .reviewCommentCreated(sessionId: sessionId, comment: comment)

      case "review_comment_updated":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let comment = try container.decode(ServerReviewComment.self, forKey: .comment)
        self = .reviewCommentUpdated(sessionId: sessionId, comment: comment)

      case "review_comment_deleted":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let commentId = try container.decode(String.self, forKey: .commentId)
        self = .reviewCommentDeleted(sessionId: sessionId, commentId: commentId)

      case "review_comments_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let comments = try container.decode([ServerReviewComment].self, forKey: .comments)
        self = .reviewCommentsList(sessionId: sessionId, comments: comments)

      case "subagent_tools_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let subagentId = try container.decode(String.self, forKey: .subagentId)
        let tools = try container.decode([ServerSubagentTool].self, forKey: .tools)
        self = .subagentToolsList(sessionId: sessionId, subagentId: subagentId, tools: tools)

      case "shell_started":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let requestId = try container.decode(String.self, forKey: .requestId)
        let command = try container.decode(String.self, forKey: .command)
        self = .shellStarted(sessionId: sessionId, requestId: requestId, command: command)

      case "shell_output":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let requestId = try container.decode(String.self, forKey: .requestId)
        let stdout = try container.decode(String.self, forKey: .stdout)
        let stderr = try container.decode(String.self, forKey: .stderr)
        let exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        let durationMs = try container.decode(UInt64.self, forKey: .durationMs)
        let outcome = try container.decodeIfPresent(ServerShellExecutionOutcome.self, forKey: .outcome)
          ?? ((exitCode == 0) ? .completed : .failed)
        self = .shellOutput(
          sessionId: sessionId, requestId: requestId,
          stdout: stdout, stderr: stderr, exitCode: exitCode, durationMs: durationMs, outcome: outcome
        )

      case "directory_listing":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let path = try container.decode(String.self, forKey: .path)
        let entries = try container.decode([ServerDirectoryEntry].self, forKey: .entries)
        self = .directoryListing(requestId: requestId, path: path, entries: entries)

      case "recent_projects_list":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let projects = try container.decode([ServerRecentProject].self, forKey: .projects)
        self = .recentProjectsList(requestId: requestId, projects: projects)

      case "codex_usage_result":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let usage = try container.decodeIfPresent(ServerCodexUsageSnapshot.self, forKey: .usage)
        let errorInfo = try container.decodeIfPresent(ServerUsageErrorInfo.self, forKey: .errorInfo)
        self = .codexUsageResult(requestId: requestId, usage: usage, errorInfo: errorInfo)

      case "claude_usage_result":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let usage = try container.decodeIfPresent(ServerClaudeUsageSnapshot.self, forKey: .usage)
        let errorInfo = try container.decodeIfPresent(ServerUsageErrorInfo.self, forKey: .errorInfo)
        self = .claudeUsageResult(requestId: requestId, usage: usage, errorInfo: errorInfo)

      case "open_ai_key_status":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let configured = try container.decode(Bool.self, forKey: .configured)
        self = .openAiKeyStatus(requestId: requestId, configured: configured)

      case "server_info":
        let isPrimary = try container.decode(Bool.self, forKey: .isPrimary)
        let clientPrimaryClaims =
          try container.decodeIfPresent([ServerClientPrimaryClaim].self, forKey: .clientPrimaryClaims) ?? []
        self = .serverInfo(isPrimary: isPrimary, clientPrimaryClaims: clientPrimaryClaims)

      case "approval_decision_result":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let requestId = try container.decode(String.self, forKey: .requestId)
        let outcome = try container.decode(String.self, forKey: .outcome)
        let activeRequestId = try container.decodeIfPresent(String.self, forKey: .activeRequestId)
        let approvalVersion = try container.decode(UInt64.self, forKey: .approvalVersion)
        self = .approvalDecisionResult(
          sessionId: sessionId,
          requestId: requestId,
          outcome: outcome,
          activeRequestId: activeRequestId,
          approvalVersion: approvalVersion
        )

      case "worktrees_list":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let repoRoot = try container.decodeIfPresent(String.self, forKey: .repoRoot)
        let worktrees = try container.decode([ServerWorktreeSummary].self, forKey: .worktrees)
        self = .worktreesList(requestId: requestId, repoRoot: repoRoot, worktrees: worktrees)

      case "worktree_created":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let worktree = try container.decode(ServerWorktreeSummary.self, forKey: .worktree)
        self = .worktreeCreated(requestId: requestId, worktree: worktree)

      case "worktree_removed":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let worktreeId = try container.decode(String.self, forKey: .worktreeId)
        self = .worktreeRemoved(requestId: requestId, worktreeId: worktreeId)

      case "worktree_status_changed":
        let worktreeId = try container.decode(String.self, forKey: .worktreeId)
        let status = try container.decode(ServerWorktreeStatus.self, forKey: .status)
        let repoRoot = try container.decode(String.self, forKey: .repoRoot)
        self = .worktreeStatusChanged(worktreeId: worktreeId, status: status, repoRoot: repoRoot)

      case "worktree_error":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let code = try container.decode(String.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        self = .worktreeError(requestId: requestId, code: code, message: message)

      case "rate_limit_event":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let info = try container.decode(ServerRateLimitInfo.self, forKey: .info)
        self = .rateLimitEvent(sessionId: sessionId, info: info)

      case "prompt_suggestion":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let suggestion = try container.decode(String.self, forKey: .suggestion)
        self = .promptSuggestion(sessionId: sessionId, suggestion: suggestion)

      case "files_persisted":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
        self = .filesPersisted(sessionId: sessionId, files: files)

      case "error":
        let code = try container.decode(String.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self = .error(code: code, message: message, sessionId: sessionId)

      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Unknown message type: \(type)"
          )
        )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case let .sessionsList(sessions):
        try container.encode("sessions_list", forKey: .type)
        try container.encode(sessions, forKey: .sessions)

      case let .sessionSnapshot(session):
        try container.encode("session_snapshot", forKey: .type)
        try container.encode(session, forKey: .session)

      case let .sessionDelta(sessionId, changes):
        try container.encode("session_delta", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(changes, forKey: .changes)

      case let .messageAppended(sessionId, message):
        try container.encode("message_appended", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(message, forKey: .message)

      case let .messageUpdated(sessionId, messageId, changes):
        try container.encode("message_updated", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(changes, forKey: .changes)

      case let .approvalRequested(sessionId, request, approvalVersion):
        try container.encode("approval_requested", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(approvalVersion, forKey: .approvalVersion)

      case let .tokensUpdated(sessionId, usage, snapshotKind):
        try container.encode("tokens_updated", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(usage, forKey: .usage)
        try container.encode(snapshotKind, forKey: .snapshotKind)

      case let .sessionCreated(session):
        try container.encode("session_created", forKey: .type)
        try container.encode(session, forKey: .session)

      case let .sessionEnded(sessionId, reason):
        try container.encode("session_ended", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(reason, forKey: .reason)

      case let .approvalsList(sessionId, approvals):
        try container.encode("approvals_list", forKey: .type)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(approvals, forKey: .approvals)

      case let .approvalDeleted(approvalId):
        try container.encode("approval_deleted", forKey: .type)
        try container.encode(approvalId, forKey: .approvalId)

      case let .modelsList(models):
        try container.encode("models_list", forKey: .type)
        try container.encode(models, forKey: .models)

      case let .codexAccountStatus(status):
        try container.encode("codex_account_status", forKey: .type)
        try container.encode(status, forKey: .status)

      case let .codexLoginChatgptStarted(loginId, authUrl):
        try container.encode("codex_login_chatgpt_started", forKey: .type)
        try container.encode(loginId, forKey: .loginId)
        try container.encode(authUrl, forKey: .authUrl)

      case let .codexLoginChatgptCompleted(loginId, success, error):
        try container.encode("codex_login_chatgpt_completed", forKey: .type)
        try container.encode(loginId, forKey: .loginId)
        try container.encode(success, forKey: .success)
        try container.encodeIfPresent(error, forKey: .error)

      case let .codexLoginChatgptCanceled(loginId, status):
        try container.encode("codex_login_chatgpt_canceled", forKey: .type)
        try container.encode(loginId, forKey: .loginId)
        try container.encode(status, forKey: .status)

      case let .codexAccountUpdated(status):
        try container.encode("codex_account_updated", forKey: .type)
        try container.encode(status, forKey: .status)

      case let .skillsList(sessionId, skills, errors):
        try container.encode("skills_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(skills, forKey: .skills)
        try container.encode(errors, forKey: .errors)

      case let .remoteSkillsList(sessionId, skills):
        try container.encode("remote_skills_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(skills, forKey: .skills)

      case let .remoteSkillDownloaded(sessionId, skillId, name, path):
        try container.encode("remote_skill_downloaded", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(skillId, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)

      case let .skillsUpdateAvailable(sessionId):
        try container.encode("skills_update_available", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .mcpToolsList(sessionId, tools, resources, resourceTemplates, authStatuses):
        try container.encode("mcp_tools_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(tools, forKey: .tools)
        try container.encode(resources, forKey: .resources)
        try container.encode(resourceTemplates, forKey: .resourceTemplates)
        try container.encode(authStatuses, forKey: .authStatuses)

      case let .mcpStartupUpdate(sessionId, server, status):
        try container.encode("mcp_startup_update", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(server, forKey: .server)
        try container.encode(status, forKey: .status)

      case let .mcpStartupComplete(sessionId, ready, failed, cancelled):
        try container.encode("mcp_startup_complete", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(ready, forKey: .ready)
        try container.encode(failed, forKey: .failed)
        try container.encode(cancelled, forKey: .cancelled)

      case let .claudeCapabilities(sessionId, slashCommands, skills, tools, models):
        try container.encode("claude_capabilities", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(slashCommands, forKey: .slashCommands)
        try container.encode(skills, forKey: .skills)
        try container.encode(tools, forKey: .tools)
        try container.encode(models, forKey: .models)

      case let .claudeModelsList(models):
        try container.encode("claude_models_list", forKey: .type)
        try container.encode(models, forKey: .models)

      case let .contextCompacted(sessionId):
        try container.encode("context_compacted", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .undoStarted(sessionId, message):
        try container.encode("undo_started", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(message, forKey: .message)

      case let .undoCompleted(sessionId, success, message):
        try container.encode("undo_completed", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(success, forKey: .success)
        try container.encodeIfPresent(message, forKey: .message)

      case let .threadRolledBack(sessionId, numTurns):
        try container.encode("thread_rolled_back", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(numTurns, forKey: .numTurns)

      case let .sessionForked(sourceSessionId, newSessionId, forkedFromThreadId):
        try container.encode("session_forked", forKey: .type)
        try container.encode(sourceSessionId, forKey: .sourceSessionId)
        try container.encode(newSessionId, forKey: .newSessionId)
        try container.encodeIfPresent(forkedFromThreadId, forKey: .forkedFromThreadId)

      case let .turnDiffSnapshot(
      sessionId,
      turnId,
      diff,
      inputTokens,
      outputTokens,
      cachedTokens,
      contextWindow,
      snapshotKind
    ):
        try container.encode("turn_diff_snapshot", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(turnId, forKey: .turnId)
        try container.encode(diff, forKey: .diff)
        try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try container.encodeIfPresent(outputTokens, forKey: .outputTokens)
        try container.encodeIfPresent(cachedTokens, forKey: .cachedTokens)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try container.encode(snapshotKind, forKey: .snapshotKind)

      case let .reviewCommentCreated(sessionId, comment):
        try container.encode("review_comment_created", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(comment, forKey: .comment)

      case let .reviewCommentUpdated(sessionId, comment):
        try container.encode("review_comment_updated", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(comment, forKey: .comment)

      case let .reviewCommentDeleted(sessionId, commentId):
        try container.encode("review_comment_deleted", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(commentId, forKey: .commentId)

      case let .reviewCommentsList(sessionId, comments):
        try container.encode("review_comments_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(comments, forKey: .comments)

      case let .subagentToolsList(sessionId, subagentId, tools):
        try container.encode("subagent_tools_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(subagentId, forKey: .subagentId)
        try container.encode(tools, forKey: .tools)

      case let .shellStarted(sessionId, requestId, command):
        try container.encode("shell_started", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(command, forKey: .command)

      case let .shellOutput(sessionId, requestId, stdout, stderr, exitCode, durationMs, outcome):
        try container.encode("shell_output", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(stderr, forKey: .stderr)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(outcome, forKey: .outcome)

      case let .directoryListing(requestId, path, entries):
        try container.encode("directory_listing", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(path, forKey: .path)
        try container.encode(entries, forKey: .entries)

      case let .recentProjectsList(requestId, projects):
        try container.encode("recent_projects_list", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(projects, forKey: .projects)

      case let .codexUsageResult(requestId, usage, errorInfo):
        try container.encode("codex_usage_result", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(errorInfo, forKey: .errorInfo)

      case let .claudeUsageResult(requestId, usage, errorInfo):
        try container.encode("claude_usage_result", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(errorInfo, forKey: .errorInfo)

      case let .openAiKeyStatus(requestId, configured):
        try container.encode("open_ai_key_status", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(configured, forKey: .configured)

      case let .serverInfo(isPrimary, clientPrimaryClaims):
        try container.encode("server_info", forKey: .type)
        try container.encode(isPrimary, forKey: .isPrimary)
        if !clientPrimaryClaims.isEmpty {
          try container.encode(clientPrimaryClaims, forKey: .clientPrimaryClaims)
        }

      case let .approvalDecisionResult(sessionId, requestId, outcome, activeRequestId, approvalVersion):
        try container.encode("approval_decision_result", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(activeRequestId, forKey: .activeRequestId)
        try container.encode(approvalVersion, forKey: .approvalVersion)

      case let .worktreesList(requestId, repoRoot, worktrees):
        try container.encode("worktrees_list", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(repoRoot, forKey: .repoRoot)
        try container.encode(worktrees, forKey: .worktrees)

      case let .worktreeCreated(requestId, worktree):
        try container.encode("worktree_created", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(worktree, forKey: .worktree)

      case let .worktreeRemoved(requestId, worktreeId):
        try container.encode("worktree_removed", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(worktreeId, forKey: .worktreeId)

      case let .worktreeStatusChanged(worktreeId, status, repoRoot):
        try container.encode("worktree_status_changed", forKey: .type)
        try container.encode(worktreeId, forKey: .worktreeId)
        try container.encode(status, forKey: .status)
        try container.encode(repoRoot, forKey: .repoRoot)

      case let .worktreeError(requestId, code, message):
        try container.encode("worktree_error", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)

      case let .rateLimitEvent(sessionId, info):
        try container.encode("rate_limit_event", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(info, forKey: .info)

      case let .promptSuggestion(sessionId, suggestion):
        try container.encode("prompt_suggestion", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(suggestion, forKey: .suggestion)

      case let .filesPersisted(sessionId, files):
        try container.encode("files_persisted", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(files, forKey: .files)

      case let .error(code, message, sessionId):
        try container.encode("error", forKey: .type)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
    }
  }
}

// MARK: - Client → Server Messages

enum ClientToServerMessage: Codable {
  case subscribeList
  case subscribeSession(sessionId: String, sinceRevision: UInt64? = nil, includeSnapshot: Bool = true)
  case unsubscribeSession(sessionId: String)
  case createSession(
    provider: ServerProvider,
    cwd: String,
    model: String?,
    approvalPolicy: String?,
    sandboxMode: String?,
    permissionMode: String? = nil,
    allowedTools: [String] = [],
    disallowedTools: [String] = [],
    effort: String? = nil
  )
  case sendMessage(
    sessionId: String,
    content: String,
    model: String? = nil,
    effort: String? = nil,
    skills: [ServerSkillInput] = [],
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  )
  case approveTool(
    sessionId: String,
    requestId: String,
    decision: String,
    message: String? = nil,
    interrupt: Bool? = nil
  )
  case answerQuestion(
    sessionId: String,
    requestId: String,
    answer: String,
    questionId: String? = nil,
    answers: [String: [String]]? = nil
  )
  case interruptSession(sessionId: String)
  case endSession(sessionId: String)
  case updateSessionConfig(
    sessionId: String,
    approvalPolicy: String?,
    sandboxMode: String?,
    permissionMode: String? = nil
  )
  case renameSession(sessionId: String, name: String?)
  case resumeSession(sessionId: String)
  case takeoverSession(
    sessionId: String,
    model: String? = nil,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    permissionMode: String? = nil,
    allowedTools: [String] = [],
    disallowedTools: [String] = []
  )
  case listApprovals(sessionId: String?, limit: Int?)
  case deleteApproval(approvalId: Int64)
  case listModels
  case listClaudeModels
  case codexAccountRead(refreshToken: Bool = false)
  case codexLoginChatgptStart
  case codexLoginChatgptCancel(loginId: String)
  case codexAccountLogout
  case listSkills(sessionId: String, cwds: [String] = [], forceReload: Bool = false)
  case listRemoteSkills(sessionId: String)
  case downloadRemoteSkill(sessionId: String, hazelnutId: String)
  case listMcpTools(sessionId: String)
  case refreshMcpServers(sessionId: String)
  case steerTurn(
    sessionId: String,
    content: String,
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  )
  case compactContext(sessionId: String)
  case undoLastTurn(sessionId: String)
  case rollbackTurns(sessionId: String, numTurns: UInt32)
  case stopTask(sessionId: String, taskId: String)
  case rewindFiles(sessionId: String, userMessageId: String)
  case forkSession(
    sourceSessionId: String,
    nthUserMessage: UInt32? = nil,
    model: String? = nil,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    cwd: String? = nil,
    permissionMode: String? = nil,
    allowedTools: [String] = [],
    disallowedTools: [String] = []
  )
  case forkSessionToWorktree(
    sourceSessionId: String,
    branchName: String,
    baseBranch: String? = nil,
    nthUserMessage: UInt32? = nil
  )
  case forkSessionToExistingWorktree(
    sourceSessionId: String,
    worktreeId: String,
    nthUserMessage: UInt32? = nil
  )
  case createReviewComment(
    sessionId: String,
    turnId: String?,
    filePath: String,
    lineStart: UInt32,
    lineEnd: UInt32?,
    body: String,
    tag: ServerReviewCommentTag?
  )
  case updateReviewComment(
    commentId: String,
    body: String?,
    tag: ServerReviewCommentTag?,
    status: ServerReviewCommentStatus?
  )
  case deleteReviewComment(commentId: String)
  case listReviewComments(sessionId: String, turnId: String? = nil)
  case getSubagentTools(sessionId: String, subagentId: String)
  case setServerRole(isPrimary: Bool)
  case setClientPrimaryClaim(clientId: String, deviceName: String, isPrimary: Bool)
  case setOpenAiKey(key: String)
  case checkOpenAiKey(requestId: String)
  case fetchCodexUsage(requestId: String)
  case fetchClaudeUsage(requestId: String)
  case executeShell(sessionId: String, command: String, cwd: String? = nil, timeoutSecs: UInt64 = 30)
  case cancelShell(sessionId: String, requestId: String)
  case browseDirectory(path: String? = nil, requestId: String)
  case listRecentProjects(requestId: String)
  case listWorktrees(requestId: String, repoRoot: String? = nil)
  case createWorktree(requestId: String, repoPath: String, branchName: String, baseBranch: String? = nil)
  case removeWorktree(requestId: String, worktreeId: String, force: Bool = false)
  case discoverWorktrees(requestId: String, repoPath: String)

  enum CodingKeys: String, CodingKey {
    case type
    case sessionId = "session_id"
    case sourceSessionId = "source_session_id"
    case provider
    case cwd
    case model
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
    case content
    case requestId = "request_id"
    case questionId = "question_id"
    case decision
    case answer
    case answers
    case name
    case effort
    case limit
    case approvalId = "approval_id"
    case refreshToken = "refresh_token"
    case loginId = "login_id"
    case skills
    case images
    case mentions
    case cwds
    case forceReload = "force_reload"
    case hazelnutId = "hazelnut_id"
    case numTurns = "num_turns"
    case nthUserMessage = "nth_user_message"
    case sinceRevision = "since_revision"
    case includeSnapshot = "include_snapshot"
    case turnId = "turn_id"
    case filePath = "file_path"
    case lineStart = "line_start"
    case lineEnd = "line_end"
    case body
    case tag
    case commentId = "comment_id"
    case status
    case key
    case subagentId = "subagent_id"
    case command
    case timeoutSecs = "timeout_secs"
    case permissionMode = "permission_mode"
    case allowedTools = "allowed_tools"
    case disallowedTools = "disallowed_tools"
    case message
    case interrupt
    case path
    case isPrimary = "is_primary"
    case clientId = "client_id"
    case deviceName = "device_name"
    case repoRoot = "repo_root"
    case repoPath = "repo_path"
    case branchName = "branch_name"
    case baseBranch = "base_branch"
    case worktreeId = "worktree_id"
    case force
    case taskId = "task_id"
    case userMessageId = "user_message_id"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case .subscribeList:
        try container.encode("subscribe_list", forKey: .type)

      case let .subscribeSession(sessionId, sinceRevision, includeSnapshot):
        try container.encode("subscribe_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(sinceRevision, forKey: .sinceRevision)
        if !includeSnapshot {
          try container.encode(false, forKey: .includeSnapshot)
        }

      case let .unsubscribeSession(sessionId):
        try container.encode("unsubscribe_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .createSession(
      provider,
      cwd,
      model,
      approvalPolicy,
      sandboxMode,
      permissionMode,
      allowedTools,
      disallowedTools,
      effort
    ):
        try container.encode("create_session", forKey: .type)
        try container.encode(provider, forKey: .provider)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)
        try container.encodeIfPresent(permissionMode, forKey: .permissionMode)
        if !allowedTools.isEmpty {
          try container.encode(allowedTools, forKey: .allowedTools)
        }
        if !disallowedTools.isEmpty {
          try container.encode(disallowedTools, forKey: .disallowedTools)
        }
        try container.encodeIfPresent(effort, forKey: .effort)

      case let .sendMessage(sessionId, content, model, effort, skills, images, mentions):
        try container.encode("send_message", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(effort, forKey: .effort)
        if !skills.isEmpty {
          try container.encode(skills, forKey: .skills)
        }
        if !images.isEmpty {
          try container.encode(images, forKey: .images)
        }
        if !mentions.isEmpty {
          try container.encode(mentions, forKey: .mentions)
        }

      case let .approveTool(sessionId, requestId, decision, message, interrupt):
        try container.encode("approve_tool", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(decision, forKey: .decision)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(interrupt, forKey: .interrupt)

      case let .answerQuestion(sessionId, requestId, answer, questionId, answers):
        try container.encode("answer_question", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(answer, forKey: .answer)
        try container.encodeIfPresent(questionId, forKey: .questionId)
        try container.encodeIfPresent(answers, forKey: .answers)

      case let .interruptSession(sessionId):
        try container.encode("interrupt_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .endSession(sessionId):
        try container.encode("end_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .updateSessionConfig(sessionId, approvalPolicy, sandboxMode, permissionMode):
        try container.encode("update_session_config", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)
        try container.encodeIfPresent(permissionMode, forKey: .permissionMode)

      case let .renameSession(sessionId, name):
        try container.encode("rename_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(name, forKey: .name)

      case let .resumeSession(sessionId):
        try container.encode("resume_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .takeoverSession(
      sessionId,
      model,
      approvalPolicy,
      sandboxMode,
      permissionMode,
      allowedTools,
      disallowedTools
    ):
        try container.encode("takeover_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)
        try container.encodeIfPresent(permissionMode, forKey: .permissionMode)
        if !allowedTools.isEmpty {
          try container.encode(allowedTools, forKey: .allowedTools)
        }
        if !disallowedTools.isEmpty {
          try container.encode(disallowedTools, forKey: .disallowedTools)
        }

      case let .listApprovals(sessionId, limit):
        try container.encode("list_approvals", forKey: .type)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(limit, forKey: .limit)

      case let .deleteApproval(approvalId):
        try container.encode("delete_approval", forKey: .type)
        try container.encode(approvalId, forKey: .approvalId)

      case .listModels:
        try container.encode("list_models", forKey: .type)

      case .listClaudeModels:
        try container.encode("list_claude_models", forKey: .type)

      case let .codexAccountRead(refreshToken):
        try container.encode("codex_account_read", forKey: .type)
        if refreshToken {
          try container.encode(refreshToken, forKey: .refreshToken)
        }

      case .codexLoginChatgptStart:
        try container.encode("codex_login_chatgpt_start", forKey: .type)

      case let .codexLoginChatgptCancel(loginId):
        try container.encode("codex_login_chatgpt_cancel", forKey: .type)
        try container.encode(loginId, forKey: .loginId)

      case .codexAccountLogout:
        try container.encode("codex_account_logout", forKey: .type)

      case let .listSkills(sessionId, cwds, forceReload):
        try container.encode("list_skills", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        if !cwds.isEmpty {
          try container.encode(cwds, forKey: .cwds)
        }
        if forceReload {
          try container.encode(forceReload, forKey: .forceReload)
        }

      case let .listRemoteSkills(sessionId):
        try container.encode("list_remote_skills", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .downloadRemoteSkill(sessionId, hazelnutId):
        try container.encode("download_remote_skill", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(hazelnutId, forKey: .hazelnutId)

      case let .listMcpTools(sessionId):
        try container.encode("list_mcp_tools", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .refreshMcpServers(sessionId):
        try container.encode("refresh_mcp_servers", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .steerTurn(sessionId, content, images, mentions):
        try container.encode("steer_turn", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(content, forKey: .content)
        if !images.isEmpty {
          try container.encode(images, forKey: .images)
        }
        if !mentions.isEmpty {
          try container.encode(mentions, forKey: .mentions)
        }

      case let .compactContext(sessionId):
        try container.encode("compact_context", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .undoLastTurn(sessionId):
        try container.encode("undo_last_turn", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .rollbackTurns(sessionId, numTurns):
        try container.encode("rollback_turns", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(numTurns, forKey: .numTurns)

      case let .stopTask(sessionId, taskId):
        try container.encode("stop_task", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(taskId, forKey: .taskId)

      case let .rewindFiles(sessionId, userMessageId):
        try container.encode("rewind_files", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(userMessageId, forKey: .userMessageId)

      case let .forkSession(
      sourceSessionId,
      nthUserMessage,
      model,
      approvalPolicy,
      sandboxMode,
      cwd,
      permissionMode,
      allowedTools,
      disallowedTools
    ):
        try container.encode("fork_session", forKey: .type)
        try container.encode(sourceSessionId, forKey: .sourceSessionId)
        try container.encodeIfPresent(nthUserMessage, forKey: .nthUserMessage)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(permissionMode, forKey: .permissionMode)
        if !allowedTools.isEmpty {
          try container.encode(allowedTools, forKey: .allowedTools)
        }
        if !disallowedTools.isEmpty {
          try container.encode(disallowedTools, forKey: .disallowedTools)
        }

      case let .forkSessionToWorktree(sourceSessionId, branchName, baseBranch, nthUserMessage):
        try container.encode("fork_session_to_worktree", forKey: .type)
        try container.encode(sourceSessionId, forKey: .sourceSessionId)
        try container.encode(branchName, forKey: .branchName)
        try container.encodeIfPresent(baseBranch, forKey: .baseBranch)
        try container.encodeIfPresent(nthUserMessage, forKey: .nthUserMessage)

      case let .forkSessionToExistingWorktree(sourceSessionId, worktreeId, nthUserMessage):
        try container.encode("fork_session_to_existing_worktree", forKey: .type)
        try container.encode(sourceSessionId, forKey: .sourceSessionId)
        try container.encode(worktreeId, forKey: .worktreeId)
        try container.encodeIfPresent(nthUserMessage, forKey: .nthUserMessage)

      case let .createReviewComment(sessionId, turnId, filePath, lineStart, lineEnd, body, tag):
        try container.encode("create_review_comment", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(turnId, forKey: .turnId)
        try container.encode(filePath, forKey: .filePath)
        try container.encode(lineStart, forKey: .lineStart)
        try container.encodeIfPresent(lineEnd, forKey: .lineEnd)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(tag, forKey: .tag)

      case let .updateReviewComment(commentId, body, tag, status):
        try container.encode("update_review_comment", forKey: .type)
        try container.encode(commentId, forKey: .commentId)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encodeIfPresent(tag, forKey: .tag)
        try container.encodeIfPresent(status, forKey: .status)

      case let .deleteReviewComment(commentId):
        try container.encode("delete_review_comment", forKey: .type)
        try container.encode(commentId, forKey: .commentId)

      case let .listReviewComments(sessionId, turnId):
        try container.encode("list_review_comments", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(turnId, forKey: .turnId)

      case let .getSubagentTools(sessionId, subagentId):
        try container.encode("get_subagent_tools", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(subagentId, forKey: .subagentId)

      case let .setServerRole(isPrimary):
        try container.encode("set_server_role", forKey: .type)
        try container.encode(isPrimary, forKey: .isPrimary)

      case let .setClientPrimaryClaim(clientId, deviceName, isPrimary):
        try container.encode("set_client_primary_claim", forKey: .type)
        try container.encode(clientId, forKey: .clientId)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(isPrimary, forKey: .isPrimary)

      case let .setOpenAiKey(key):
        try container.encode("set_open_ai_key", forKey: .type)
        try container.encode(key, forKey: .key)

      case let .checkOpenAiKey(requestId):
        try container.encode("check_open_ai_key", forKey: .type)
        try container.encode(requestId, forKey: .requestId)

      case let .fetchCodexUsage(requestId):
        try container.encode("fetch_codex_usage", forKey: .type)
        try container.encode(requestId, forKey: .requestId)

      case let .fetchClaudeUsage(requestId):
        try container.encode("fetch_claude_usage", forKey: .type)
        try container.encode(requestId, forKey: .requestId)

      case let .executeShell(sessionId, command, cwd, timeoutSecs):
        try container.encode("execute_shell", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        if timeoutSecs != 30 {
          try container.encode(timeoutSecs, forKey: .timeoutSecs)
        }

      case let .cancelShell(sessionId, requestId):
        try container.encode("cancel_shell", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)

      case let .browseDirectory(path, requestId):
        try container.encode("browse_directory", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(path, forKey: .path)

      case let .listRecentProjects(requestId):
        try container.encode("list_recent_projects", forKey: .type)
        try container.encode(requestId, forKey: .requestId)

      case let .listWorktrees(requestId, repoRoot):
        try container.encode("list_worktrees", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(repoRoot, forKey: .repoRoot)

      case let .createWorktree(requestId, repoPath, branchName, baseBranch):
        try container.encode("create_worktree", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(repoPath, forKey: .repoPath)
        try container.encode(branchName, forKey: .branchName)
        try container.encodeIfPresent(baseBranch, forKey: .baseBranch)

      case let .removeWorktree(requestId, worktreeId, force):
        try container.encode("remove_worktree", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(worktreeId, forKey: .worktreeId)
        if force {
          try container.encode(force, forKey: .force)
        }

      case let .discoverWorktrees(requestId, repoPath):
        try container.encode("discover_worktrees", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(repoPath, forKey: .repoPath)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
      case "subscribe_list":
        self = .subscribeList
      case "subscribe_session":
        self = try .subscribeSession(
          sessionId: container.decode(String.self, forKey: .sessionId),
          sinceRevision: container.decodeIfPresent(UInt64.self, forKey: .sinceRevision),
          includeSnapshot: container.decodeIfPresent(Bool.self, forKey: .includeSnapshot) ?? true
        )
      case "unsubscribe_session":
        self = try .unsubscribeSession(sessionId: container.decode(String.self, forKey: .sessionId))
      case "create_session":
        self = try .createSession(
          provider: container.decode(ServerProvider.self, forKey: .provider),
          cwd: container.decode(String.self, forKey: .cwd),
          model: container.decodeIfPresent(String.self, forKey: .model),
          approvalPolicy: container.decodeIfPresent(String.self, forKey: .approvalPolicy),
          sandboxMode: container.decodeIfPresent(String.self, forKey: .sandboxMode),
          permissionMode: container.decodeIfPresent(String.self, forKey: .permissionMode),
          allowedTools: container.decodeIfPresent([String].self, forKey: .allowedTools) ?? [],
          disallowedTools: container.decodeIfPresent([String].self, forKey: .disallowedTools) ?? [],
          effort: container.decodeIfPresent(String.self, forKey: .effort)
        )
      case "send_message":
        self = try .sendMessage(
          sessionId: container.decode(String.self, forKey: .sessionId),
          content: container.decode(String.self, forKey: .content),
          model: container.decodeIfPresent(String.self, forKey: .model),
          effort: container.decodeIfPresent(String.self, forKey: .effort),
          skills: container.decodeIfPresent([ServerSkillInput].self, forKey: .skills) ?? [],
          images: container.decodeIfPresent([ServerImageInput].self, forKey: .images) ?? [],
          mentions: container.decodeIfPresent([ServerMentionInput].self, forKey: .mentions) ?? []
        )
      case "approve_tool":
        self = try .approveTool(
          sessionId: container.decode(String.self, forKey: .sessionId),
          requestId: container.decode(String.self, forKey: .requestId),
          decision: container.decode(String.self, forKey: .decision),
          message: container.decodeIfPresent(String.self, forKey: .message),
          interrupt: container.decodeIfPresent(Bool.self, forKey: .interrupt)
        )
      case "answer_question":
        self = try .answerQuestion(
          sessionId: container.decode(String.self, forKey: .sessionId),
          requestId: container.decode(String.self, forKey: .requestId),
          answer: container.decode(String.self, forKey: .answer),
          questionId: container.decodeIfPresent(String.self, forKey: .questionId),
          answers: container.decodeIfPresent([String: [String]].self, forKey: .answers)
        )
      case "interrupt_session":
        self = try .interruptSession(sessionId: container.decode(String.self, forKey: .sessionId))
      case "end_session":
        self = try .endSession(sessionId: container.decode(String.self, forKey: .sessionId))
      case "update_session_config":
        self = try .updateSessionConfig(
          sessionId: container.decode(String.self, forKey: .sessionId),
          approvalPolicy: container.decodeIfPresent(String.self, forKey: .approvalPolicy),
          sandboxMode: container.decodeIfPresent(String.self, forKey: .sandboxMode),
          permissionMode: container.decodeIfPresent(String.self, forKey: .permissionMode)
        )
      case "rename_session":
        self = try .renameSession(
          sessionId: container.decode(String.self, forKey: .sessionId),
          name: container.decodeIfPresent(String.self, forKey: .name)
        )
      case "resume_session":
        self = try .resumeSession(sessionId: container.decode(String.self, forKey: .sessionId))
      case "takeover_session":
        self = try .takeoverSession(
          sessionId: container.decode(String.self, forKey: .sessionId),
          model: container.decodeIfPresent(String.self, forKey: .model),
          approvalPolicy: container.decodeIfPresent(String.self, forKey: .approvalPolicy),
          sandboxMode: container.decodeIfPresent(String.self, forKey: .sandboxMode),
          permissionMode: container.decodeIfPresent(String.self, forKey: .permissionMode),
          allowedTools: (try? container.decode([String].self, forKey: .allowedTools)) ?? [],
          disallowedTools: (try? container.decode([String].self, forKey: .disallowedTools)) ?? []
        )
      case "list_approvals":
        self = try .listApprovals(
          sessionId: container.decodeIfPresent(String.self, forKey: .sessionId),
          limit: container.decodeIfPresent(Int.self, forKey: .limit)
        )
      case "delete_approval":
        self = try .deleteApproval(approvalId: container.decode(Int64.self, forKey: .approvalId))
      case "list_models":
        self = .listModels
      case "list_claude_models":
        self = .listClaudeModels
      case "codex_account_read":
        self = try .codexAccountRead(
          refreshToken: container.decodeIfPresent(Bool.self, forKey: .refreshToken) ?? false
        )
      case "codex_login_chatgpt_start":
        self = .codexLoginChatgptStart
      case "codex_login_chatgpt_cancel":
        self = try .codexLoginChatgptCancel(
          loginId: container.decode(String.self, forKey: .loginId)
        )
      case "codex_account_logout":
        self = .codexAccountLogout
      case "list_skills":
        self = try .listSkills(
          sessionId: container.decode(String.self, forKey: .sessionId),
          cwds: container.decodeIfPresent([String].self, forKey: .cwds) ?? [],
          forceReload: container.decodeIfPresent(Bool.self, forKey: .forceReload) ?? false
        )
      case "list_remote_skills":
        self = try .listRemoteSkills(sessionId: container.decode(String.self, forKey: .sessionId))
      case "download_remote_skill":
        self = try .downloadRemoteSkill(
          sessionId: container.decode(String.self, forKey: .sessionId),
          hazelnutId: container.decode(String.self, forKey: .hazelnutId)
        )
      case "list_mcp_tools":
        self = try .listMcpTools(sessionId: container.decode(String.self, forKey: .sessionId))
      case "refresh_mcp_servers":
        self = try .refreshMcpServers(sessionId: container.decode(String.self, forKey: .sessionId))
      case "steer_turn":
        self = try .steerTurn(
          sessionId: container.decode(String.self, forKey: .sessionId),
          content: container.decode(String.self, forKey: .content),
          images: container.decodeIfPresent([ServerImageInput].self, forKey: .images) ?? [],
          mentions: container.decodeIfPresent([ServerMentionInput].self, forKey: .mentions) ?? []
        )
      case "compact_context":
        self = try .compactContext(sessionId: container.decode(String.self, forKey: .sessionId))
      case "undo_last_turn":
        self = try .undoLastTurn(sessionId: container.decode(String.self, forKey: .sessionId))
      case "rollback_turns":
        self = try .rollbackTurns(
          sessionId: container.decode(String.self, forKey: .sessionId),
          numTurns: container.decode(UInt32.self, forKey: .numTurns)
        )
      case "fork_session":
        self = try .forkSession(
          sourceSessionId: container.decode(String.self, forKey: .sourceSessionId),
          nthUserMessage: container.decodeIfPresent(UInt32.self, forKey: .nthUserMessage),
          model: container.decodeIfPresent(String.self, forKey: .model),
          approvalPolicy: container.decodeIfPresent(String.self, forKey: .approvalPolicy),
          sandboxMode: container.decodeIfPresent(String.self, forKey: .sandboxMode),
          cwd: container.decodeIfPresent(String.self, forKey: .cwd),
          permissionMode: container.decodeIfPresent(String.self, forKey: .permissionMode),
          allowedTools: container.decodeIfPresent([String].self, forKey: .allowedTools) ?? [],
          disallowedTools: container.decodeIfPresent([String].self, forKey: .disallowedTools) ?? []
        )
      case "fork_session_to_worktree":
        self = try .forkSessionToWorktree(
          sourceSessionId: container.decode(String.self, forKey: .sourceSessionId),
          branchName: container.decode(String.self, forKey: .branchName),
          baseBranch: container.decodeIfPresent(String.self, forKey: .baseBranch),
          nthUserMessage: container.decodeIfPresent(UInt32.self, forKey: .nthUserMessage)
        )
      case "fork_session_to_existing_worktree":
        self = try .forkSessionToExistingWorktree(
          sourceSessionId: container.decode(String.self, forKey: .sourceSessionId),
          worktreeId: container.decode(String.self, forKey: .worktreeId),
          nthUserMessage: container.decodeIfPresent(UInt32.self, forKey: .nthUserMessage)
        )
      case "create_review_comment":
        self = try .createReviewComment(
          sessionId: container.decode(String.self, forKey: .sessionId),
          turnId: container.decodeIfPresent(String.self, forKey: .turnId),
          filePath: container.decode(String.self, forKey: .filePath),
          lineStart: container.decode(UInt32.self, forKey: .lineStart),
          lineEnd: container.decodeIfPresent(UInt32.self, forKey: .lineEnd),
          body: container.decode(String.self, forKey: .body),
          tag: container.decodeIfPresent(ServerReviewCommentTag.self, forKey: .tag)
        )
      case "update_review_comment":
        self = try .updateReviewComment(
          commentId: container.decode(String.self, forKey: .commentId),
          body: container.decodeIfPresent(String.self, forKey: .body),
          tag: container.decodeIfPresent(ServerReviewCommentTag.self, forKey: .tag),
          status: container.decodeIfPresent(ServerReviewCommentStatus.self, forKey: .status)
        )
      case "delete_review_comment":
        self = try .deleteReviewComment(commentId: container.decode(String.self, forKey: .commentId))
      case "list_review_comments":
        self = try .listReviewComments(
          sessionId: container.decode(String.self, forKey: .sessionId),
          turnId: container.decodeIfPresent(String.self, forKey: .turnId)
        )
      case "get_subagent_tools":
        self = try .getSubagentTools(
          sessionId: container.decode(String.self, forKey: .sessionId),
          subagentId: container.decode(String.self, forKey: .subagentId)
        )
      case "set_server_role":
        self = try .setServerRole(
          isPrimary: container.decode(Bool.self, forKey: .isPrimary)
        )
      case "set_client_primary_claim":
        self = try .setClientPrimaryClaim(
          clientId: container.decode(String.self, forKey: .clientId),
          deviceName: container.decode(String.self, forKey: .deviceName),
          isPrimary: container.decode(Bool.self, forKey: .isPrimary)
        )
      case "set_open_ai_key":
        self = try .setOpenAiKey(
          key: container.decode(String.self, forKey: .key)
        )
      case "check_open_ai_key":
        self = try .checkOpenAiKey(
          requestId: container.decode(String.self, forKey: .requestId)
        )
      case "fetch_codex_usage":
        self = try .fetchCodexUsage(
          requestId: container.decode(String.self, forKey: .requestId)
        )
      case "fetch_claude_usage":
        self = try .fetchClaudeUsage(
          requestId: container.decode(String.self, forKey: .requestId)
        )
      case "execute_shell":
        self = try .executeShell(
          sessionId: container.decode(String.self, forKey: .sessionId),
          command: container.decode(String.self, forKey: .command),
          cwd: container.decodeIfPresent(String.self, forKey: .cwd),
          timeoutSecs: container.decodeIfPresent(UInt64.self, forKey: .timeoutSecs) ?? 30
        )
      case "cancel_shell":
        self = try .cancelShell(
          sessionId: container.decode(String.self, forKey: .sessionId),
          requestId: container.decode(String.self, forKey: .requestId)
        )
      case "browse_directory":
        self = try .browseDirectory(
          path: container.decodeIfPresent(String.self, forKey: .path),
          requestId: container.decode(String.self, forKey: .requestId)
        )
      case "list_recent_projects":
        self = try .listRecentProjects(
          requestId: container.decode(String.self, forKey: .requestId)
        )
      case "list_worktrees":
        self = try .listWorktrees(
          requestId: container.decode(String.self, forKey: .requestId),
          repoRoot: container.decodeIfPresent(String.self, forKey: .repoRoot)
        )
      case "create_worktree":
        self = try .createWorktree(
          requestId: container.decode(String.self, forKey: .requestId),
          repoPath: container.decode(String.self, forKey: .repoPath),
          branchName: container.decode(String.self, forKey: .branchName),
          baseBranch: container.decodeIfPresent(String.self, forKey: .baseBranch)
        )
      case "remove_worktree":
        self = try .removeWorktree(
          requestId: container.decode(String.self, forKey: .requestId),
          worktreeId: container.decode(String.self, forKey: .worktreeId),
          force: container.decodeIfPresent(Bool.self, forKey: .force) ?? false
        )
      case "discover_worktrees":
        self = try .discoverWorktrees(
          requestId: container.decode(String.self, forKey: .requestId),
          repoPath: container.decode(String.self, forKey: .repoPath)
        )
      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Unknown message type: \(type)"
          )
        )
    }
  }
}
