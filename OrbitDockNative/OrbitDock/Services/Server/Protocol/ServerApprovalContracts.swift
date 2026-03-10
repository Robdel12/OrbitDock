//
//  ServerApprovalContracts.swift
//  OrbitDock
//
//  Approval and permission protocol contracts.
//

import Foundation

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
  let permissionSuggestions: AnyCodable?

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
    case permissionSuggestions = "permission_suggestions"
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
    proposedAmendment: [String]? = nil,
    permissionSuggestions: AnyCodable? = nil
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
    self.permissionSuggestions = permissionSuggestions
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
    permissionSuggestions = try container.decodeIfPresent(AnyCodable.self, forKey: .permissionSuggestions)
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
    try container.encodeIfPresent(permissionSuggestions, forKey: .permissionSuggestions)
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
  let toolInput: String?
  let command: String?
  let filePath: String?
  let diff: String?
  let question: String?
  let questionPrompts: [ServerApprovalQuestionPrompt]
  let preview: ServerApprovalPreview?
  let cwd: String?
  let decision: String?
  let proposedAmendment: [String]?
  let permissionSuggestions: AnyCodable?
  let createdAt: String
  let decidedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case requestId = "request_id"
    case approvalType = "approval_type"
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case command
    case filePath = "file_path"
    case diff
    case question
    case questionPrompts = "question_prompts"
    case preview
    case cwd
    case decision
    case proposedAmendment = "proposed_amendment"
    case permissionSuggestions = "permission_suggestions"
    case createdAt = "created_at"
    case decidedAt = "decided_at"
  }

  init(
    id: Int64,
    sessionId: String,
    requestId: String,
    approvalType: ServerApprovalType,
    toolName: String? = nil,
    toolInput: String? = nil,
    command: String? = nil,
    filePath: String? = nil,
    diff: String? = nil,
    question: String? = nil,
    questionPrompts: [ServerApprovalQuestionPrompt] = [],
    preview: ServerApprovalPreview? = nil,
    cwd: String? = nil,
    decision: String? = nil,
    proposedAmendment: [String]? = nil,
    permissionSuggestions: AnyCodable? = nil,
    createdAt: String,
    decidedAt: String? = nil
  ) {
    self.id = id
    self.sessionId = sessionId
    self.requestId = requestId
    self.approvalType = approvalType
    self.toolName = toolName
    self.toolInput = toolInput
    self.command = command
    self.filePath = filePath
    self.diff = diff
    self.question = question
    self.questionPrompts = questionPrompts
    self.preview = preview
    self.cwd = cwd
    self.decision = decision
    self.proposedAmendment = proposedAmendment
    self.permissionSuggestions = permissionSuggestions
    self.createdAt = createdAt
    self.decidedAt = decidedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    requestId = try container.decode(String.self, forKey: .requestId)
    approvalType = try container.decode(ServerApprovalType.self, forKey: .approvalType)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    toolInput = try container.decodeIfPresent(String.self, forKey: .toolInput)
    command = try container.decodeIfPresent(String.self, forKey: .command)
    filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
    diff = try container.decodeIfPresent(String.self, forKey: .diff)
    question = try container.decodeIfPresent(String.self, forKey: .question)
    questionPrompts =
      try container.decodeIfPresent([ServerApprovalQuestionPrompt].self, forKey: .questionPrompts) ?? []
    preview = try container.decodeIfPresent(ServerApprovalPreview.self, forKey: .preview)
    cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    decision = try container.decodeIfPresent(String.self, forKey: .decision)
    proposedAmendment = try container.decodeIfPresent([String].self, forKey: .proposedAmendment)
    permissionSuggestions = try container.decodeIfPresent(AnyCodable.self, forKey: .permissionSuggestions)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    decidedAt = try container.decodeIfPresent(String.self, forKey: .decidedAt)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(requestId, forKey: .requestId)
    try container.encode(approvalType, forKey: .approvalType)
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
    try container.encodeIfPresent(cwd, forKey: .cwd)
    try container.encodeIfPresent(decision, forKey: .decision)
    try container.encodeIfPresent(proposedAmendment, forKey: .proposedAmendment)
    try container.encodeIfPresent(permissionSuggestions, forKey: .permissionSuggestions)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(decidedAt, forKey: .decidedAt)
  }
}

// MARK: - Permission Rules

struct ServerPermissionRule: Codable, Identifiable {
  let pattern: String
  let behavior: String

  var id: String {
    "\(behavior):\(pattern)"
  }
}

enum ServerSessionPermissionRules: Codable {
  case claude(
    permissionMode: String?,
    rules: [ServerPermissionRule],
    additionalDirectories: [String]?
  )
  case codex(
    approvalPolicy: String?,
    sandboxMode: String?
  )

  enum CodingKeys: String, CodingKey {
    case provider
    case permissionMode = "permission_mode"
    case rules
    case additionalDirectories = "additional_directories"
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let provider = try container.decode(String.self, forKey: .provider)

    switch provider {
      case "claude":
        let mode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        let rules = try container.decodeIfPresent([ServerPermissionRule].self, forKey: .rules) ?? []
        let dirs = try container.decodeIfPresent([String].self, forKey: .additionalDirectories)
        self = .claude(permissionMode: mode, rules: rules, additionalDirectories: dirs)
      case "codex":
        let policy = try container.decodeIfPresent(String.self, forKey: .approvalPolicy)
        let sandbox = try container.decodeIfPresent(String.self, forKey: .sandboxMode)
        self = .codex(approvalPolicy: policy, sandboxMode: sandbox)
      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Unknown provider: \(provider)"
          )
        )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case let .claude(mode, rules, dirs):
        try container.encode("claude", forKey: .provider)
        try container.encodeIfPresent(mode, forKey: .permissionMode)
        try container.encode(rules, forKey: .rules)
        try container.encodeIfPresent(dirs, forKey: .additionalDirectories)
      case let .codex(policy, sandbox):
        try container.encode("codex", forKey: .provider)
        try container.encodeIfPresent(policy, forKey: .approvalPolicy)
        try container.encodeIfPresent(sandbox, forKey: .sandboxMode)
    }
  }
}

struct PermissionRuleMutationBody: Codable {
  let pattern: String
  let behavior: String
  let scope: String
}

struct ModifyPermissionRuleHTTPResponse: Codable {
  let ok: Bool
}

struct ServerPermissionRulesResponse: Codable {
  let sessionId: String
  let rules: ServerSessionPermissionRules

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case rules
  }
}
