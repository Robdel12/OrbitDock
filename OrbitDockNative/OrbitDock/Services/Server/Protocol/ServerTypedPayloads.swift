//
//  ServerTypedPayloads.swift
//  OrbitDock
//
//  Strongly-typed payload structs mirroring Rust protocol types.
//  Replaces AnyCodable fields on row structs for decode-time validation.
//

import Foundation

// MARK: - Worker State (mirrors WorkerStateSnapshot)

struct ServerWorkerStateSnapshot: Codable {
  let id: String
  let label: String?
  let agentType: String?
  let provider: ServerProvider?
  let model: String?
  let status: ServerConversationToolStatus
  let taskSummary: String?
  let resultSummary: String?
  let errorSummary: String?
  let parentWorkerId: String?
  let startedAt: String?
  let lastActivityAt: String?
  let endedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case label
    case agentType = "agent_type"
    case provider
    case model
    case status
    case taskSummary = "task_summary"
    case resultSummary = "result_summary"
    case errorSummary = "error_summary"
    case parentWorkerId = "parent_worker_id"
    case startedAt = "started_at"
    case lastActivityAt = "last_activity_at"
    case endedAt = "ended_at"
  }
}

// MARK: - Plan Mode (mirrors PlanModePayload)

struct ServerPlanModePayload: Codable {
  let mode: String?
  let summary: String?
  let steps: [ServerPlanStep]
  let reviewMode: String?
  let explanation: String?

  enum CodingKeys: String, CodingKey {
    case mode
    case summary
    case steps
    case reviewMode = "review_mode"
    case explanation
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decodeIfPresent(String.self, forKey: .mode)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    steps = try container.decodeIfPresent([ServerPlanStep].self, forKey: .steps) ?? []
    reviewMode = try container.decodeIfPresent(String.self, forKey: .reviewMode)
    explanation = try container.decodeIfPresent(String.self, forKey: .explanation)
  }
}

struct ServerPlanStep: Codable {
  let id: String?
  let title: String
  let status: ServerPlanStepStatus
  let detail: String?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case status
    case detail
  }
}

enum ServerPlanStepStatus: String, Codable {
  case pending
  case inProgress = "in_progress"
  case completed
  case failed
  case cancelled
}

// MARK: - Hook (mirrors HookPayload)

struct ServerHookPayload: Codable {
  let hookName: String?
  let eventName: String?
  let phase: String?
  let status: String?
  let sourcePath: String?
  let summary: String?
  let output: String?
  let durationMs: UInt64?
  let entries: [ServerHookOutputEntry]

  enum CodingKeys: String, CodingKey {
    case hookName = "hook_name"
    case eventName = "event_name"
    case phase
    case status
    case sourcePath = "source_path"
    case summary
    case output
    case durationMs = "duration_ms"
    case entries
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hookName = try container.decodeIfPresent(String.self, forKey: .hookName)
    eventName = try container.decodeIfPresent(String.self, forKey: .eventName)
    phase = try container.decodeIfPresent(String.self, forKey: .phase)
    status = try container.decodeIfPresent(String.self, forKey: .status)
    sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    output = try container.decodeIfPresent(String.self, forKey: .output)
    durationMs = try container.decodeIfPresent(UInt64.self, forKey: .durationMs)
    entries = try container.decodeIfPresent([ServerHookOutputEntry].self, forKey: .entries) ?? []
  }
}

struct ServerHookOutputEntry: Codable {
  let kind: String?
  let label: String?
  let value: String?
}

// MARK: - Handoff (mirrors HandoffPayload)

struct ServerHandoffPayload: Codable {
  let target: String?
  let summary: String?
  let body: String?
  let transcriptExcerpt: String?

  enum CodingKeys: String, CodingKey {
    case target
    case summary
    case body
    case transcriptExcerpt = "transcript_excerpt"
  }
}

// MARK: - Question Response (mirrors QuestionResponseValue, tagged with "response_type")

enum ServerQuestionResponseValue: Codable {
  case text(value: String)
  case choice(optionId: String, label: String)
  case choices(optionIds: [String])
  case structured(value: AnyCodable)

  enum CodingKeys: String, CodingKey {
    case responseType = "response_type"
    case value
    case optionId = "option_id"
    case label
    case optionIds = "option_ids"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .responseType)
    switch type {
      case "text":
        let value = try container.decode(String.self, forKey: .value)
        self = .text(value: value)
      case "choice":
        let optionId = try container.decode(String.self, forKey: .optionId)
        let label = try container.decode(String.self, forKey: .label)
        self = .choice(optionId: optionId, label: label)
      case "choices":
        let optionIds = try container.decode([String].self, forKey: .optionIds)
        self = .choices(optionIds: optionIds)
      case "structured":
        let value = try container.decode(AnyCodable.self, forKey: .value)
        self = .structured(value: value)
      default:
        let value = try container.decodeIfPresent(AnyCodable.self, forKey: .value) ?? AnyCodable(type)
        self = .structured(value: value)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case let .text(value):
        try container.encode("text", forKey: .responseType)
        try container.encode(value, forKey: .value)
      case let .choice(optionId, label):
        try container.encode("choice", forKey: .responseType)
        try container.encode(optionId, forKey: .optionId)
        try container.encode(label, forKey: .label)
      case let .choices(optionIds):
        try container.encode("choices", forKey: .responseType)
        try container.encode(optionIds, forKey: .optionIds)
      case let .structured(value):
        try container.encode("structured", forKey: .responseType)
        try container.encode(value, forKey: .value)
    }
  }
}

// MARK: - Tool Preview (mirrors ToolPreviewPayload, externally-tagged serde)

enum ServerToolPreviewPayload: Codable {
  case text(value: String)
  case diff(additions: UInt32, deletions: UInt32, snippet: String)
  case todos(total: UInt32, completed: UInt32)
  case search(matches: UInt32, summary: String?)
  case worker(label: String?, status: String?)
  case questions(count: UInt32, summary: String?)
  case image(count: UInt32, summary: String?)

  /// Externally-tagged serde: {"Text": {"value": "..."}}
  enum OuterKey: String, CodingKey {
    case Text, Diff, Todos, Search, Worker, Questions, Image
  }

  enum TextKeys: String, CodingKey { case value }
  enum DiffKeys: String, CodingKey { case additions, deletions, snippet }
  enum TodosKeys: String, CodingKey { case total, completed }
  enum SearchKeys: String, CodingKey { case matches, summary }
  enum WorkerKeys: String, CodingKey { case label, status }
  enum QuestionsKeys: String, CodingKey { case count, summary }
  enum ImageKeys: String, CodingKey { case count, summary }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: OuterKey.self)

    if container.contains(.Text) {
      let nested = try container.nestedContainer(keyedBy: TextKeys.self, forKey: .Text)
      self = try .text(value: nested.decode(String.self, forKey: .value))
    } else if container.contains(.Diff) {
      let nested = try container.nestedContainer(keyedBy: DiffKeys.self, forKey: .Diff)
      self = try .diff(
        additions: nested.decode(UInt32.self, forKey: .additions),
        deletions: nested.decode(UInt32.self, forKey: .deletions),
        snippet: nested.decode(String.self, forKey: .snippet)
      )
    } else if container.contains(.Todos) {
      let nested = try container.nestedContainer(keyedBy: TodosKeys.self, forKey: .Todos)
      self = try .todos(
        total: nested.decode(UInt32.self, forKey: .total),
        completed: nested.decode(UInt32.self, forKey: .completed)
      )
    } else if container.contains(.Search) {
      let nested = try container.nestedContainer(keyedBy: SearchKeys.self, forKey: .Search)
      self = try .search(
        matches: nested.decode(UInt32.self, forKey: .matches),
        summary: nested.decodeIfPresent(String.self, forKey: .summary)
      )
    } else if container.contains(.Worker) {
      let nested = try container.nestedContainer(keyedBy: WorkerKeys.self, forKey: .Worker)
      self = try .worker(
        label: nested.decodeIfPresent(String.self, forKey: .label),
        status: nested.decodeIfPresent(String.self, forKey: .status)
      )
    } else if container.contains(.Questions) {
      let nested = try container.nestedContainer(keyedBy: QuestionsKeys.self, forKey: .Questions)
      self = try .questions(
        count: nested.decode(UInt32.self, forKey: .count),
        summary: nested.decodeIfPresent(String.self, forKey: .summary)
      )
    } else if container.contains(.Image) {
      let nested = try container.nestedContainer(keyedBy: ImageKeys.self, forKey: .Image)
      self = try .image(
        count: nested.decode(UInt32.self, forKey: .count),
        summary: nested.decodeIfPresent(String.self, forKey: .summary)
      )
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Unknown ToolPreviewPayload variant"
        )
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: OuterKey.self)
    switch self {
      case let .text(value):
        var nested = container.nestedContainer(keyedBy: TextKeys.self, forKey: .Text)
        try nested.encode(value, forKey: .value)
      case let .diff(additions, deletions, snippet):
        var nested = container.nestedContainer(keyedBy: DiffKeys.self, forKey: .Diff)
        try nested.encode(additions, forKey: .additions)
        try nested.encode(deletions, forKey: .deletions)
        try nested.encode(snippet, forKey: .snippet)
      case let .todos(total, completed):
        var nested = container.nestedContainer(keyedBy: TodosKeys.self, forKey: .Todos)
        try nested.encode(total, forKey: .total)
        try nested.encode(completed, forKey: .completed)
      case let .search(matches, summary):
        var nested = container.nestedContainer(keyedBy: SearchKeys.self, forKey: .Search)
        try nested.encode(matches, forKey: .matches)
        try nested.encodeIfPresent(summary, forKey: .summary)
      case let .worker(label, status):
        var nested = container.nestedContainer(keyedBy: WorkerKeys.self, forKey: .Worker)
        try nested.encodeIfPresent(label, forKey: .label)
        try nested.encodeIfPresent(status, forKey: .status)
      case let .questions(count, summary):
        var nested = container.nestedContainer(keyedBy: QuestionsKeys.self, forKey: .Questions)
        try nested.encode(count, forKey: .count)
        try nested.encodeIfPresent(summary, forKey: .summary)
      case let .image(count, summary):
        var nested = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .Image)
        try nested.encode(count, forKey: .count)
        try nested.encodeIfPresent(summary, forKey: .summary)
    }
  }
}

// MARK: - Permission Descriptor (mirrors PermissionDescriptor, tagged with "kind")

enum ServerPermissionDescriptor: Codable {
  case filesystem(readPaths: [String], writePaths: [String])
  case network(hosts: [String])
  case macOs(entitlement: String, details: String?)
  case generic(permission: String, details: String?)

  enum CodingKeys: String, CodingKey {
    case kind
    case readPaths = "read_paths"
    case writePaths = "write_paths"
    case hosts
    case entitlement
    case details
    case permission
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
      case "filesystem":
        let readPaths = try container.decodeIfPresent([String].self, forKey: .readPaths) ?? []
        let writePaths = try container.decodeIfPresent([String].self, forKey: .writePaths) ?? []
        self = .filesystem(readPaths: readPaths, writePaths: writePaths)
      case "network":
        let hosts = try container.decodeIfPresent([String].self, forKey: .hosts) ?? []
        self = .network(hosts: hosts)
      case "mac_os":
        let entitlement = try container.decode(String.self, forKey: .entitlement)
        let details = try container.decodeIfPresent(String.self, forKey: .details)
        self = .macOs(entitlement: entitlement, details: details)
      default:
        let permission = try container.decodeIfPresent(String.self, forKey: .permission) ?? kind
        let details = try container.decodeIfPresent(String.self, forKey: .details)
        self = .generic(permission: permission, details: details)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case let .filesystem(readPaths, writePaths):
        try container.encode("filesystem", forKey: .kind)
        try container.encode(readPaths, forKey: .readPaths)
        try container.encode(writePaths, forKey: .writePaths)
      case let .network(hosts):
        try container.encode("network", forKey: .kind)
        try container.encode(hosts, forKey: .hosts)
      case let .macOs(entitlement, details):
        try container.encode("mac_os", forKey: .kind)
        try container.encode(entitlement, forKey: .entitlement)
        try container.encodeIfPresent(details, forKey: .details)
      case let .generic(permission, details):
        try container.encode("generic", forKey: .kind)
        try container.encode(permission, forKey: .permission)
        try container.encodeIfPresent(details, forKey: .details)
    }
  }
}

// MARK: - Permission Suggestion (Claude SDK PermissionUpdate format)

/// Matches the Claude SDK `PermissionUpdate` wire format:
/// `{"type": "addRules", "behavior": "allow", "destination": "localSettings", "rules": [...]}`
struct ServerPermissionSuggestion: Codable {
  let type: String
  let behavior: String?
  let destination: String?
  let rules: [ServerPermissionSuggestionRule]

  enum CodingKeys: String, CodingKey {
    case type
    case behavior
    case destination
    case rules
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decode(String.self, forKey: .type)
    behavior = try container.decodeIfPresent(String.self, forKey: .behavior)
    destination = try container.decodeIfPresent(String.self, forKey: .destination)
    rules = try container.decodeIfPresent([ServerPermissionSuggestionRule].self, forKey: .rules) ?? []
  }
}

struct ServerPermissionSuggestionRule: Codable {
  let ruleContent: String?
  let toolName: String?

  enum CodingKeys: String, CodingKey {
    case ruleContent
    case toolName
  }
}

// MARK: - Elicitation Mode (Part 4)

enum ServerElicitationMode: String, Codable {
  case form
  case url
}
