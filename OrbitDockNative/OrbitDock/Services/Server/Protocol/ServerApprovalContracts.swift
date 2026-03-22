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
  let permissionReason: String?
  let requestedPermissions: [ServerPermissionDescriptor]?
  let grantedPermissions: [ServerPermissionDescriptor]?
  let proposedAmendment: [String]?
  /// Raw permission suggestions from Claude SDK (PermissionUpdate[]).
  /// Opaque JSON — the SDK format doesn't match PermissionDescriptor.
  let permissionSuggestions: [ServerPermissionSuggestion]?
  let elicitationMode: ServerElicitationMode?
  let elicitationSchema: AnyCodable?
  let elicitationUrl: String?
  let elicitationMessage: String?
  let mcpServerName: String?
  let networkHost: String?
  let networkProtocol: String?

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
    case permissionReason = "permission_reason"
    case requestedPermissions = "requested_permissions"
    case grantedPermissions = "granted_permissions"
    case proposedAmendment = "proposed_amendment"
    case permissionSuggestions = "permission_suggestions"
    case elicitationMode = "elicitation_mode"
    case elicitationSchema = "elicitation_schema"
    case elicitationUrl = "elicitation_url"
    case elicitationMessage = "elicitation_message"
    case mcpServerName = "mcp_server_name"
    case networkHost = "network_host"
    case networkProtocol = "network_protocol"
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
    permissionReason: String? = nil,
    requestedPermissions: [ServerPermissionDescriptor]? = nil,
    grantedPermissions: [ServerPermissionDescriptor]? = nil,
    proposedAmendment: [String]? = nil,
    permissionSuggestions: [ServerPermissionSuggestion]? = nil,
    elicitationMode: ServerElicitationMode? = nil,
    elicitationSchema: AnyCodable? = nil,
    elicitationUrl: String? = nil,
    elicitationMessage: String? = nil,
    mcpServerName: String? = nil,
    networkHost: String? = nil,
    networkProtocol: String? = nil
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
    self.permissionReason = permissionReason
    self.requestedPermissions = requestedPermissions
    self.grantedPermissions = grantedPermissions
    self.proposedAmendment = proposedAmendment
    self.permissionSuggestions = permissionSuggestions
    self.elicitationMode = elicitationMode
    self.elicitationSchema = elicitationSchema
    self.elicitationUrl = elicitationUrl
    self.elicitationMessage = elicitationMessage
    self.mcpServerName = mcpServerName
    self.networkHost = networkHost
    self.networkProtocol = networkProtocol
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
    permissionReason = try container.decodeIfPresent(String.self, forKey: .permissionReason)
    requestedPermissions = try container.decodePermissionDescriptors(forKey: .requestedPermissions)
    grantedPermissions = try container.decodePermissionDescriptors(forKey: .grantedPermissions)
    proposedAmendment = try container.decodeIfPresent([String].self, forKey: .proposedAmendment)
    permissionSuggestions = try container.decodeIfPresent(
      [ServerPermissionSuggestion].self,
      forKey: .permissionSuggestions
    )
    elicitationMode = try container.decodeIfPresent(ServerElicitationMode.self, forKey: .elicitationMode)
    elicitationSchema = try container.decodeIfPresent(AnyCodable.self, forKey: .elicitationSchema)
    elicitationUrl = try container.decodeIfPresent(String.self, forKey: .elicitationUrl)
    elicitationMessage = try container.decodeIfPresent(String.self, forKey: .elicitationMessage)
    mcpServerName = try container.decodeIfPresent(String.self, forKey: .mcpServerName)
    networkHost = try container.decodeIfPresent(String.self, forKey: .networkHost)
    networkProtocol = try container.decodeIfPresent(String.self, forKey: .networkProtocol)
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
    try container.encodeIfPresent(permissionReason, forKey: .permissionReason)
    if let perms = requestedPermissions, !perms.isEmpty {
      try container.encode(perms, forKey: .requestedPermissions)
    }
    if let perms = grantedPermissions, !perms.isEmpty {
      try container.encode(perms, forKey: .grantedPermissions)
    }
    try container.encodeIfPresent(proposedAmendment, forKey: .proposedAmendment)
    try container.encodeIfPresent(permissionSuggestions, forKey: .permissionSuggestions)
    try container.encodeIfPresent(elicitationMode, forKey: .elicitationMode)
    try container.encodeIfPresent(elicitationSchema, forKey: .elicitationSchema)
    try container.encodeIfPresent(elicitationUrl, forKey: .elicitationUrl)
    try container.encodeIfPresent(elicitationMessage, forKey: .elicitationMessage)
    try container.encodeIfPresent(mcpServerName, forKey: .mcpServerName)
    try container.encodeIfPresent(networkHost, forKey: .networkHost)
    try container.encodeIfPresent(networkProtocol, forKey: .networkProtocol)
  }
}

enum ServerApprovalType: String, Codable {
  case exec
  case patch
  case question
  case permissions
}

enum ServerPermissionGrantScope: String, Codable, CaseIterable, Identifiable {
  case turn
  case session

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .turn: "This Turn"
      case .session: "This Session"
    }
  }
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
  let permissionReason: String?
  let requestedPermissions: [ServerPermissionDescriptor]?
  let grantedPermissions: [ServerPermissionDescriptor]?
  let cwd: String?
  let decision: String?
  let proposedAmendment: [String]?
  /// Raw permission suggestions from Claude SDK (PermissionUpdate[]).
  /// Opaque JSON — the SDK format doesn't match PermissionDescriptor.
  let permissionSuggestions: [ServerPermissionSuggestion]?
  let elicitationMode: ServerElicitationMode?
  let elicitationSchema: AnyCodable?
  let elicitationUrl: String?
  let elicitationMessage: String?
  let mcpServerName: String?
  let networkHost: String?
  let networkProtocol: String?
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
    case permissionReason = "permission_reason"
    case requestedPermissions = "requested_permissions"
    case grantedPermissions = "granted_permissions"
    case cwd
    case decision
    case proposedAmendment = "proposed_amendment"
    case permissionSuggestions = "permission_suggestions"
    case elicitationMode = "elicitation_mode"
    case elicitationSchema = "elicitation_schema"
    case elicitationUrl = "elicitation_url"
    case elicitationMessage = "elicitation_message"
    case mcpServerName = "mcp_server_name"
    case networkHost = "network_host"
    case networkProtocol = "network_protocol"
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
    permissionReason: String? = nil,
    requestedPermissions: [ServerPermissionDescriptor]? = nil,
    grantedPermissions: [ServerPermissionDescriptor]? = nil,
    cwd: String? = nil,
    decision: String? = nil,
    proposedAmendment: [String]? = nil,
    permissionSuggestions: [ServerPermissionSuggestion]? = nil,
    elicitationMode: ServerElicitationMode? = nil,
    elicitationSchema: AnyCodable? = nil,
    elicitationUrl: String? = nil,
    elicitationMessage: String? = nil,
    mcpServerName: String? = nil,
    networkHost: String? = nil,
    networkProtocol: String? = nil,
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
    self.permissionReason = permissionReason
    self.requestedPermissions = requestedPermissions
    self.grantedPermissions = grantedPermissions
    self.cwd = cwd
    self.decision = decision
    self.proposedAmendment = proposedAmendment
    self.permissionSuggestions = permissionSuggestions
    self.elicitationMode = elicitationMode
    self.elicitationSchema = elicitationSchema
    self.elicitationUrl = elicitationUrl
    self.elicitationMessage = elicitationMessage
    self.mcpServerName = mcpServerName
    self.networkHost = networkHost
    self.networkProtocol = networkProtocol
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
    permissionReason = try container.decodeIfPresent(String.self, forKey: .permissionReason)
    requestedPermissions = try container.decodePermissionDescriptors(forKey: .requestedPermissions)
    grantedPermissions = try container.decodePermissionDescriptors(forKey: .grantedPermissions)
    cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    decision = try container.decodeIfPresent(String.self, forKey: .decision)
    proposedAmendment = try container.decodeIfPresent([String].self, forKey: .proposedAmendment)
    permissionSuggestions = try container.decodeIfPresent(
      [ServerPermissionSuggestion].self,
      forKey: .permissionSuggestions
    )
    elicitationMode = try container.decodeIfPresent(ServerElicitationMode.self, forKey: .elicitationMode)
    elicitationSchema = try container.decodeIfPresent(AnyCodable.self, forKey: .elicitationSchema)
    elicitationUrl = try container.decodeIfPresent(String.self, forKey: .elicitationUrl)
    elicitationMessage = try container.decodeIfPresent(String.self, forKey: .elicitationMessage)
    mcpServerName = try container.decodeIfPresent(String.self, forKey: .mcpServerName)
    networkHost = try container.decodeIfPresent(String.self, forKey: .networkHost)
    networkProtocol = try container.decodeIfPresent(String.self, forKey: .networkProtocol)
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
    try container.encodeIfPresent(permissionReason, forKey: .permissionReason)
    if let perms = requestedPermissions, !perms.isEmpty {
      try container.encode(perms, forKey: .requestedPermissions)
    }
    if let perms = grantedPermissions, !perms.isEmpty {
      try container.encode(perms, forKey: .grantedPermissions)
    }
    try container.encodeIfPresent(cwd, forKey: .cwd)
    try container.encodeIfPresent(decision, forKey: .decision)
    try container.encodeIfPresent(proposedAmendment, forKey: .proposedAmendment)
    if let suggestions = permissionSuggestions, !suggestions.isEmpty {
      try container.encode(suggestions, forKey: .permissionSuggestions)
    }
    try container.encodeIfPresent(elicitationMode, forKey: .elicitationMode)
    try container.encodeIfPresent(elicitationSchema, forKey: .elicitationSchema)
    try container.encodeIfPresent(elicitationUrl, forKey: .elicitationUrl)
    try container.encodeIfPresent(elicitationMessage, forKey: .elicitationMessage)
    try container.encodeIfPresent(mcpServerName, forKey: .mcpServerName)
    try container.encodeIfPresent(networkHost, forKey: .networkHost)
    try container.encodeIfPresent(networkProtocol, forKey: .networkProtocol)
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
    approvalPolicyDetails: ServerCodexApprovalPolicy?,
    sandboxMode: String?
  )

  enum CodingKeys: String, CodingKey {
    case provider
    case permissionMode = "permission_mode"
    case rules
    case additionalDirectories = "additional_directories"
    case approvalPolicy = "approval_policy"
    case approvalPolicyDetails = "approval_policy_details"
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
        let details = try container.decodeIfPresent(
          ServerCodexApprovalPolicy.self,
          forKey: .approvalPolicyDetails
        )
        let sandbox = try container.decodeIfPresent(String.self, forKey: .sandboxMode)
        self = .codex(approvalPolicy: policy, approvalPolicyDetails: details, sandboxMode: sandbox)
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
      case let .codex(policy, details, sandbox):
        try container.encode("codex", forKey: .provider)
        try container.encodeIfPresent(policy, forKey: .approvalPolicy)
        try container.encodeIfPresent(details, forKey: .approvalPolicyDetails)
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

// MARK: - Resilient Permission Decoding

/// Decodes permission descriptors from either:
/// 1. Typed `[ServerPermissionDescriptor]` (future server format)
/// 2. Legacy flat dict `{"network": {...}, "file_system": {...}, "macos": {...}}` (current format)
extension KeyedDecodingContainer {
  func decodePermissionDescriptors(
    forKey key: Key
  ) throws -> [ServerPermissionDescriptor]? {
    guard contains(key), try !decodeNil(forKey: key) else { return nil }

    // Try typed array first (future format)
    if let typed = try? decode([ServerPermissionDescriptor].self, forKey: key) {
      return typed
    }

    // Fall back to legacy dict transform
    guard let raw = try? decode(AnyCodable.self, forKey: key),
          let dict = raw.value as? [String: Any]
    else { return nil }

    return ServerPermissionDescriptorLegacy.parse(dict)
  }
}

/// Transforms the legacy flat-dict permission format into typed descriptors.
enum ServerPermissionDescriptorLegacy {
  static func parse(_ dict: [String: Any]) -> [ServerPermissionDescriptor] {
    var result: [ServerPermissionDescriptor] = []

    // Network: {"network": {"enabled": true}} or {"network": {"hosts": [...]}}
    if let network = dict["network"] as? [String: Any] {
      if let hosts = network["hosts"] as? [String], !hosts.isEmpty {
        result.append(.network(hosts: hosts))
      } else if (network["enabled"] as? Bool) == true {
        result.append(.network(hosts: []))
      }
    }

    // Filesystem: {"file_system": {"read": [...], "write": [...]}}
    if let fs = dict["file_system"] as? [String: Any] {
      let readPaths = (fs["read"] as? [String]) ?? []
      let writePaths = (fs["write"] as? [String]) ?? []
      if !readPaths.isEmpty || !writePaths.isEmpty {
        result.append(.filesystem(readPaths: readPaths, writePaths: writePaths))
      }
    }

    // macOS: {"macos": {"macos_preferences": "read_write", ...}}
    if let macos = dict["macos"] as? [String: Any] {
      if let prefs = (macos["macos_preferences"] ?? macos["preferences"]) as? String {
        result.append(.macOs(entitlement: "preferences", details: prefs))
      }
      let automation = macos["macos_automation"] ?? macos["automations"]
      if let mode = automation as? String {
        result.append(.macOs(entitlement: "automation", details: mode))
      } else if let autoDict = automation as? [String: Any],
                let bundleIds = autoDict["bundle_ids"] as? [String]
      {
        for id in bundleIds {
          result.append(.macOs(entitlement: "automation", details: id))
        }
      } else if let bundleIds = automation as? [String] {
        for id in bundleIds {
          result.append(.macOs(entitlement: "automation", details: id))
        }
      }
      if (macos["macos_accessibility"] ?? macos["accessibility"]) as? Bool == true {
        result.append(.macOs(entitlement: "accessibility", details: nil))
      }
      if (macos["macos_calendar"] ?? macos["calendar"]) as? Bool == true {
        result.append(.macOs(entitlement: "calendar", details: nil))
      }
    }

    return result
  }
}
