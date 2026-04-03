import Foundation

enum ServerControlDeckDensity: String, Codable, Sendable {
  case comfortable
  case compact
}

enum ServerControlDeckEmptyVisibility: String, Codable, Sendable {
  case auto
  case always
  case hidden
}

enum ServerControlDeckModule: String, Codable, Sendable {
  case connection
  case autonomy
  case approvalMode = "approval_mode"
  case collaborationMode = "collaboration_mode"
  case autoReview = "auto_review"
  case tokens
  case model
  case effort
  case branch
  case cwd
  case attachments
}

struct ServerControlDeckModulePreference: Codable, Sendable {
  let module: ServerControlDeckModule
  let visible: Bool
}

struct ServerControlDeckPreferences: Codable, Sendable {
  let density: ServerControlDeckDensity
  let showWhenEmpty: ServerControlDeckEmptyVisibility
  let modules: [ServerControlDeckModulePreference]

  enum CodingKeys: String, CodingKey {
    case density
    case showWhenEmpty = "show_when_empty"
    case modules
  }
}

struct ServerControlDeckConfigState: Codable, Sendable {
  let model: String?
  let effort: String?
  let approvalPolicy: String?
  let approvalPolicyDetails: ServerCodexApprovalPolicy?
  let sandboxMode: String?
  let approvalsReviewer: ServerCodexApprovalsReviewer?
  let permissionMode: String?
  let collaborationMode: String?
  let developerInstructions: String?
  let codexConfigMode: ServerCodexConfigMode?
  let codexConfigProfile: String?
  let codexModelProvider: String?

  enum CodingKeys: String, CodingKey {
    case model
    case effort
    case approvalPolicy = "approval_policy"
    case approvalPolicyDetails = "approval_policy_details"
    case sandboxMode = "sandbox_mode"
    case approvalsReviewer = "approvals_reviewer"
    case permissionMode = "permission_mode"
    case collaborationMode = "collaboration_mode"
    case developerInstructions = "developer_instructions"
    case codexConfigMode = "codex_config_mode"
    case codexConfigProfile = "codex_config_profile"
    case codexModelProvider = "codex_model_provider"
  }
}

struct ServerControlDeckState: Codable, Sendable {
  let provider: ServerProvider
  let controlMode: ServerSessionControlMode
  let lifecycleState: ServerSessionLifecycleState
  let acceptsUserInput: Bool
  let steerable: Bool
  let projectPath: String
  let currentCwd: String?
  let gitBranch: String?
  let config: ServerControlDeckConfigState

  enum CodingKeys: String, CodingKey {
    case provider
    case controlMode = "control_mode"
    case lifecycleState = "lifecycle_state"
    case acceptsUserInput = "accepts_user_input"
    case steerable
    case projectPath = "project_path"
    case currentCwd = "current_cwd"
    case gitBranch = "git_branch"
    case config
  }
}

struct ServerControlDeckCapabilities: Codable, Sendable {
  let supportsSkills: Bool
  let supportsMentions: Bool
  let supportsImages: Bool
  let supportsSteer: Bool
  let allowPerTurnModelOverride: Bool
  let allowPerTurnEffortOverride: Bool
  let effortOptions: [ServerControlDeckPickerOption]
  let approvalModeOptions: [ServerControlDeckPickerOption]
  let permissionModeOptions: [ServerControlDeckPickerOption]
  let collaborationModeOptions: [ServerControlDeckPickerOption]
  let autoReviewOptions: [ServerControlDeckAutoReviewOption]
  let availableStatusModules: [ServerControlDeckModule]

  enum CodingKeys: String, CodingKey {
    case supportsSkills = "supports_skills"
    case supportsMentions = "supports_mentions"
    case supportsImages = "supports_images"
    case supportsSteer = "supports_steer"
    case allowPerTurnModelOverride = "allow_per_turn_model_override"
    case allowPerTurnEffortOverride = "allow_per_turn_effort_override"
    case effortOptions = "effort_options"
    case approvalModeOptions = "approval_mode_options"
    case permissionModeOptions = "permission_mode_options"
    case collaborationModeOptions = "collaboration_mode_options"
    case autoReviewOptions = "auto_review_options"
    case availableStatusModules = "available_status_modules"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    supportsSkills = try container.decode(Bool.self, forKey: .supportsSkills)
    supportsMentions = try container.decode(Bool.self, forKey: .supportsMentions)
    supportsImages = try container.decode(Bool.self, forKey: .supportsImages)
    supportsSteer = try container.decode(Bool.self, forKey: .supportsSteer)
    allowPerTurnModelOverride = try container.decode(Bool.self, forKey: .allowPerTurnModelOverride)
    allowPerTurnEffortOverride = try container.decode(Bool.self, forKey: .allowPerTurnEffortOverride)
    effortOptions = try container.decodeIfPresent([ServerControlDeckPickerOption].self, forKey: .effortOptions) ?? []
    approvalModeOptions = try container.decodeIfPresent([ServerControlDeckPickerOption].self, forKey: .approvalModeOptions) ?? []
    permissionModeOptions = try container.decodeIfPresent([ServerControlDeckPickerOption].self, forKey: .permissionModeOptions) ?? []
    collaborationModeOptions = try container.decodeIfPresent([ServerControlDeckPickerOption].self, forKey: .collaborationModeOptions) ?? []
    autoReviewOptions = try container.decodeIfPresent([ServerControlDeckAutoReviewOption].self, forKey: .autoReviewOptions) ?? []
    availableStatusModules = try container.decodeIfPresent([ServerControlDeckModule].self, forKey: .availableStatusModules) ?? []
  }
}

struct ServerControlDeckPickerOption: Codable, Sendable {
  let value: String
  let label: String
}

struct ServerControlDeckAutoReviewOption: Codable, Sendable {
  let value: String
  let label: String
  let approvalPolicy: String?
  let sandboxMode: String?

  enum CodingKeys: String, CodingKey {
    case value
    case label
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
  }
}

enum ServerControlDeckTokenStatusTone: String, Codable, Sendable {
  case muted
  case normal
  case caution
  case critical
}

struct ServerControlDeckTokenStatus: Codable, Sendable {
  let label: String
  let tone: ServerControlDeckTokenStatusTone
}

struct ServerControlDeckSnapshotPayload: Codable, Sendable {
  let revision: UInt64
  let sessionId: String
  let state: ServerControlDeckState
  let capabilities: ServerControlDeckCapabilities
  let preferences: ServerControlDeckPreferences
  let tokenUsage: ServerTokenUsage
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind
  let tokenStatus: ServerControlDeckTokenStatus

  enum CodingKeys: String, CodingKey {
    case revision
    case sessionId = "session_id"
    case state
    case capabilities
    case preferences
    case tokenUsage = "token_usage"
    case tokenUsageSnapshotKind = "token_usage_snapshot_kind"
    case tokenStatus = "token_status"
  }
}

struct ServerControlDeckConfigUpdateRequest: Codable, Sendable {
  var model: String?
  var effort: String?
  var approvalPolicy: String?
  var approvalPolicyDetails: ServerCodexApprovalPolicy?
  var sandboxMode: String?
  var approvalsReviewer: ServerCodexApprovalsReviewer?
  var permissionMode: String?
  var collaborationMode: String?

  enum CodingKeys: String, CodingKey {
    case model
    case effort
    case approvalPolicy = "approval_policy"
    case approvalPolicyDetails = "approval_policy_details"
    case sandboxMode = "sandbox_mode"
    case approvalsReviewer = "approvals_reviewer"
    case permissionMode = "permission_mode"
    case collaborationMode = "collaboration_mode"
  }
}

enum ServerControlDeckMentionKind: String, Codable, Sendable {
  case file
  case mcpResource = "mcp_resource"
  case url
  case symbol
  case generic
}

struct ServerControlDeckMentionRef: Codable, Sendable {
  let mentionId: String?
  let kind: ServerControlDeckMentionKind
  let name: String
  let path: String
  let relativePath: String?

  enum CodingKeys: String, CodingKey {
    case mentionId = "mention_id"
    case kind
    case name
    case path
    case relativePath = "relative_path"
  }
}

struct ServerControlDeckImageAttachmentRef: Codable, Sendable {
  let attachmentId: String
  let displayName: String?

  enum CodingKeys: String, CodingKey {
    case attachmentId = "attachment_id"
    case displayName = "display_name"
  }
}

enum ServerControlDeckAttachmentRef: Codable, Sendable {
  case mention(ServerControlDeckMentionRef)
  case image(ServerControlDeckImageAttachmentRef)

  private enum CodingKeys: String, CodingKey {
    case type
    case mentionId = "mention_id"
    case kind
    case name
    case path
    case relativePath = "relative_path"
    case attachmentId = "attachment_id"
    case displayName = "display_name"
  }

  private enum AttachmentType: String, Codable {
    case mention
    case image
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(AttachmentType.self, forKey: .type) {
      case .mention:
        self = try .mention(ServerControlDeckMentionRef(from: decoder))
      case .image:
        self = try .image(ServerControlDeckImageAttachmentRef(from: decoder))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case let .mention(value):
        try container.encode(AttachmentType.mention, forKey: .type)
        try container.encodeIfPresent(value.mentionId, forKey: .mentionId)
        try container.encode(value.kind, forKey: .kind)
        try container.encode(value.name, forKey: .name)
        try container.encode(value.path, forKey: .path)
        try container.encodeIfPresent(value.relativePath, forKey: .relativePath)
      case let .image(value):
        try container.encode(AttachmentType.image, forKey: .type)
        try container.encode(value.attachmentId, forKey: .attachmentId)
        try container.encodeIfPresent(value.displayName, forKey: .displayName)
    }
  }
}

struct ServerControlDeckSkillRef: Codable, Sendable {
  let name: String
  let path: String
}

struct ServerControlDeckTurnOverrides: Codable, Sendable {
  let model: String?
  let effort: String?
}

struct ServerControlDeckSubmitTurnRequest: Codable, Sendable {
  let text: String
  let attachments: [ServerControlDeckAttachmentRef]
  let skills: [ServerControlDeckSkillRef]
  let overrides: ServerControlDeckTurnOverrides?
}
