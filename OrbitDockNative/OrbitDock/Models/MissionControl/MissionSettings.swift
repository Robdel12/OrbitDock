import Foundation

struct MissionSettings: Codable, Equatable {
  let provider: ProviderSettings
  let agent: AgentSettings
  let trigger: TriggerSettings
  let orchestration: OrchestrationSettings
  let promptTemplate: String
  let tracker: String

  enum CodingKeys: String, CodingKey {
    case provider, agent, trigger, orchestration, tracker
    case promptTemplate = "prompt_template"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderSettings.self, forKey: .provider)
    agent = try container.decodeIfPresent(AgentSettings.self, forKey: .agent) ?? AgentSettings()
    trigger = try container.decode(TriggerSettings.self, forKey: .trigger)
    orchestration = try container.decode(OrchestrationSettings.self, forKey: .orchestration)
    promptTemplate = try container.decode(String.self, forKey: .promptTemplate)
    tracker = try container.decode(String.self, forKey: .tracker)
  }
}

struct AgentSettings: Codable, Equatable {
  let claude: ClaudeAgentSettings?
  let codex: CodexAgentSettings?

  init(claude: ClaudeAgentSettings? = nil, codex: CodexAgentSettings? = nil) {
    self.claude = claude
    self.codex = codex
  }
}

struct ClaudeAgentSettings: Codable, Equatable {
  let model: String?
  let effort: String?
  let permissionMode: String?
  let allowedTools: [String]
  let disallowedTools: [String]

  enum CodingKeys: String, CodingKey {
    case model, effort
    case permissionMode = "permission_mode"
    case allowedTools = "allowed_tools"
    case disallowedTools = "disallowed_tools"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    effort = try container.decodeIfPresent(String.self, forKey: .effort)
    permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
    allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
    disallowedTools = try container.decodeIfPresent([String].self, forKey: .disallowedTools) ?? []
  }

  init(
    model: String? = nil,
    effort: String? = nil,
    permissionMode: String? = nil,
    allowedTools: [String] = [],
    disallowedTools: [String] = []
  ) {
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.allowedTools = allowedTools
    self.disallowedTools = disallowedTools
  }
}

struct CodexAgentSettings: Codable, Equatable {
  let model: String?
  let effort: String?
  let approvalPolicy: String?
  let sandboxMode: String?
  let collaborationMode: String?
  let multiAgent: Bool?
  let personality: String?
  let serviceTier: String?
  let developerInstructions: String?

  enum CodingKeys: String, CodingKey {
    case model, effort, personality
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
    case collaborationMode = "collaboration_mode"
    case multiAgent = "multi_agent"
    case serviceTier = "service_tier"
    case developerInstructions = "developer_instructions"
  }

  init(
    model: String? = nil,
    effort: String? = nil,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    collaborationMode: String? = nil,
    multiAgent: Bool? = nil,
    personality: String? = nil,
    serviceTier: String? = nil,
    developerInstructions: String? = nil
  ) {
    self.model = model
    self.effort = effort
    self.approvalPolicy = approvalPolicy
    self.sandboxMode = sandboxMode
    self.collaborationMode = collaborationMode
    self.multiAgent = multiAgent
    self.personality = personality
    self.serviceTier = serviceTier
    self.developerInstructions = developerInstructions
  }
}

struct ProviderSettings: Codable, Equatable {
  let strategy: String
  let primary: String
  let secondary: String?
  let maxConcurrent: UInt32
  let maxConcurrentPrimary: UInt32?

  enum CodingKeys: String, CodingKey {
    case strategy, primary, secondary
    case maxConcurrent = "max_concurrent"
    case maxConcurrentPrimary = "max_concurrent_primary"
  }
}

struct TriggerSettings: Codable, Equatable {
  let kind: String
  let interval: UInt64
  let filters: TriggerFilters
}

struct TriggerFilters: Codable, Equatable {
  let labels: [String]
  let states: [String]
  let project: String?
  let team: String?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
    states = try container.decodeIfPresent([String].self, forKey: .states) ?? []
    project = try container.decodeIfPresent(String.self, forKey: .project)
    team = try container.decodeIfPresent(String.self, forKey: .team)
  }

  init(labels: [String] = [], states: [String] = [], project: String? = nil, team: String? = nil) {
    self.labels = labels
    self.states = states
    self.project = project
    self.team = team
  }
}

struct OrchestrationSettings: Codable, Equatable {
  let maxRetries: UInt32
  let stallTimeout: UInt64
  let baseBranch: String
  let worktreeRootDir: String?
  let stateOnDispatch: String
  let stateOnComplete: String

  enum CodingKeys: String, CodingKey {
    case maxRetries = "max_retries"
    case stallTimeout = "stall_timeout"
    case baseBranch = "base_branch"
    case worktreeRootDir = "worktree_root_dir"
    case stateOnDispatch = "state_on_dispatch"
    case stateOnComplete = "state_on_complete"
  }
}
