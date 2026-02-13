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
  let timestamp: String
  let durationMs: UInt64?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case type = "message_type"
    case content
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case toolOutput = "tool_output"
    case isError = "is_error"
    case timestamp
    case durationMs = "duration_ms"
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

struct ServerApprovalRequest: Codable, Identifiable {
  let id: String
  let sessionId: String
  let type: ServerApprovalType
  let command: String?
  let filePath: String?
  let diff: String?
  let question: String?
  let proposedAmendment: [String]?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case type
    case command
    case filePath = "file_path"
    case diff
    case question
    case proposedAmendment = "proposed_amendment"
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
  let status: ServerSessionStatus
  let workStatus: ServerWorkStatus
  let hasPendingApproval: Bool
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let approvalPolicy: String?
  let sandboxMode: String?
  let startedAt: String?
  let lastActivityAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case projectPath = "project_path"
    case transcriptPath = "transcript_path"
    case projectName = "project_name"
    case model
    case customName = "custom_name"
    case status
    case workStatus = "work_status"
    case hasPendingApproval = "has_pending_approval"
    case codexIntegrationMode = "codex_integration_mode"
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
    case startedAt = "started_at"
    case lastActivityAt = "last_activity_at"
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
  let status: ServerSessionStatus
  let workStatus: ServerWorkStatus
  let messages: [ServerMessage]
  let pendingApproval: ServerApprovalRequest?
  let tokenUsage: ServerTokenUsage
  let currentDiff: String?
  let currentPlan: String?
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let approvalPolicy: String?
  let sandboxMode: String?
  let startedAt: String?
  let lastActivityAt: String?
  let forkedFromSessionId: String?

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case projectPath = "project_path"
    case transcriptPath = "transcript_path"
    case projectName = "project_name"
    case model
    case customName = "custom_name"
    case status
    case workStatus = "work_status"
    case messages
    case pendingApproval = "pending_approval"
    case tokenUsage = "token_usage"
    case currentDiff = "current_diff"
    case currentPlan = "current_plan"
    case codexIntegrationMode = "codex_integration_mode"
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
    case startedAt = "started_at"
    case lastActivityAt = "last_activity_at"
    case forkedFromSessionId = "forked_from_session_id"
  }
}

// MARK: - Delta Updates

struct ServerStateChanges: Codable {
  let status: ServerSessionStatus?
  let workStatus: ServerWorkStatus?
  let pendingApproval: ServerApprovalRequest??
  let tokenUsage: ServerTokenUsage?
  let currentDiff: String??
  let currentPlan: String??
  let customName: String??
  let codexIntegrationMode: ServerCodexIntegrationMode??
  let approvalPolicy: String??
  let sandboxMode: String??
  let lastActivityAt: String?

  enum CodingKeys: String, CodingKey {
    case status
    case workStatus = "work_status"
    case pendingApproval = "pending_approval"
    case tokenUsage = "token_usage"
    case currentDiff = "current_diff"
    case currentPlan = "current_plan"
    case customName = "custom_name"
    case codexIntegrationMode = "codex_integration_mode"
    case approvalPolicy = "approval_policy"
    case sandboxMode = "sandbox_mode"
    case lastActivityAt = "last_activity_at"
  }
}

struct ServerMessageChanges: Codable {
  let content: String?
  let toolOutput: String?
  let isError: Bool?
  let durationMs: UInt64?

  enum CodingKeys: String, CodingKey {
    case content
    case toolOutput = "tool_output"
    case isError = "is_error"
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

  enum CodingKeys: String, CodingKey {
    case id
    case model
    case displayName = "display_name"
    case description
    case isDefault = "is_default"
    case supportedReasoningEfforts = "supported_reasoning_efforts"
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

  var id: String { path }

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
    case inputSchema = "inputSchema"
    case outputSchema = "outputSchema"
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
    case mimeType = "mimeType"
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
    case uriTemplate = "uriTemplate"
    case mimeType = "mimeType"
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
  case ready
  case failed(error: String)
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
      case "ready": self = .ready
      case "failed":
        let error = try container.decode(String.self, forKey: .error)
        self = .failed(error: error)
      case "cancelled": self = .cancelled
      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(codingPath: container.codingPath, debugDescription: "Unknown MCP startup state: \(state)")
        )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case .starting:
        try container.encode("starting", forKey: .state)
      case .ready:
        try container.encode("ready", forKey: .state)
      case let .failed(error):
        try container.encode("failed", forKey: .state)
        try container.encode(error, forKey: .error)
      case .cancelled:
        try container.encode("cancelled", forKey: .state)
    }
  }
}

struct ServerMcpStartupFailure: Codable {
  let server: String
  let error: String
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
      value = array.map { $0.value }
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

// MARK: - Server → Client Messages

enum ServerToClientMessage: Codable {
  case sessionsList(sessions: [ServerSessionSummary])
  case sessionSnapshot(session: ServerSessionState)
  case sessionDelta(sessionId: String, changes: ServerStateChanges)
  case messageAppended(sessionId: String, message: ServerMessage)
  case messageUpdated(sessionId: String, messageId: String, changes: ServerMessageChanges)
  case approvalRequested(sessionId: String, request: ServerApprovalRequest)
  case tokensUpdated(sessionId: String, usage: ServerTokenUsage)
  case sessionCreated(session: ServerSessionSummary)
  case sessionEnded(sessionId: String, reason: String)
  case approvalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem])
  case approvalDeleted(approvalId: Int64)
  case modelsList(models: [ServerCodexModelOption])
  case skillsList(sessionId: String, skills: [ServerSkillsListEntry], errors: [ServerSkillErrorInfo])
  case remoteSkillsList(sessionId: String, skills: [ServerRemoteSkillSummary])
  case remoteSkillDownloaded(sessionId: String, skillId: String, name: String, path: String)
  case skillsUpdateAvailable(sessionId: String)
  case mcpToolsList(sessionId: String, tools: [String: ServerMcpTool], resources: [String: [ServerMcpResource]], resourceTemplates: [String: [ServerMcpResourceTemplate]], authStatuses: [String: ServerMcpAuthStatus])
  case mcpStartupUpdate(sessionId: String, server: String, status: ServerMcpStartupStatus)
  case mcpStartupComplete(sessionId: String, ready: [String], failed: [ServerMcpStartupFailure], cancelled: [String])
  case contextCompacted(sessionId: String)
  case undoStarted(sessionId: String, message: String?)
  case undoCompleted(sessionId: String, success: Bool, message: String?)
  case threadRolledBack(sessionId: String, numTurns: UInt32)
  case sessionForked(sourceSessionId: String, newSessionId: String, forkedFromThreadId: String?)
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
    case approvals
    case approvalId = "approval_id"
    case models
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
        self = .approvalRequested(sessionId: sessionId, request: request)

      case "tokens_updated":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let usage = try container.decode(ServerTokenUsage.self, forKey: .usage)
        self = .tokensUpdated(sessionId: sessionId, usage: usage)

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
        let resourceTemplates = try container.decode([String: [ServerMcpResourceTemplate]].self, forKey: .resourceTemplates)
        let authStatuses = try container.decode([String: ServerMcpAuthStatus].self, forKey: .authStatuses)
        self = .mcpToolsList(sessionId: sessionId, tools: tools, resources: resources, resourceTemplates: resourceTemplates, authStatuses: authStatuses)

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
        self = .sessionForked(sourceSessionId: sourceSessionId, newSessionId: newSessionId, forkedFromThreadId: forkedFromThreadId)

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

      case let .approvalRequested(sessionId, request):
        try container.encode("approval_requested", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(request, forKey: .request)

      case let .tokensUpdated(sessionId, usage):
        try container.encode("tokens_updated", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(usage, forKey: .usage)

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
  case subscribeSession(sessionId: String)
  case unsubscribeSession(sessionId: String)
  case createSession(
    provider: ServerProvider,
    cwd: String,
    model: String?,
    approvalPolicy: String?,
    sandboxMode: String?
  )
  case sendMessage(sessionId: String, content: String, model: String? = nil, effort: String? = nil, skills: [ServerSkillInput] = [], images: [ServerImageInput] = [], mentions: [ServerMentionInput] = [])
  case approveTool(sessionId: String, requestId: String, decision: String)
  case answerQuestion(sessionId: String, requestId: String, answer: String)
  case interruptSession(sessionId: String)
  case endSession(sessionId: String)
  case updateSessionConfig(sessionId: String, approvalPolicy: String?, sandboxMode: String?)
  case renameSession(sessionId: String, name: String?)
  case resumeSession(sessionId: String)
  case listApprovals(sessionId: String?, limit: Int?)
  case deleteApproval(approvalId: Int64)
  case listModels
  case listSkills(sessionId: String, cwds: [String] = [], forceReload: Bool = false)
  case listRemoteSkills(sessionId: String)
  case downloadRemoteSkill(sessionId: String, hazelnutId: String)
  case listMcpTools(sessionId: String)
  case refreshMcpServers(sessionId: String)
  case steerTurn(sessionId: String, content: String)
  case compactContext(sessionId: String)
  case undoLastTurn(sessionId: String)
  case rollbackTurns(sessionId: String, numTurns: UInt32)
  case forkSession(
    sourceSessionId: String,
    nthUserMessage: UInt32? = nil,
    model: String? = nil,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    cwd: String? = nil
  )

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
    case decision
    case answer
    case name
    case effort
    case limit
    case approvalId = "approval_id"
    case skills
    case images
    case mentions
    case cwds
    case forceReload = "force_reload"
    case hazelnutId = "hazelnut_id"
    case numTurns = "num_turns"
    case nthUserMessage = "nth_user_message"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case .subscribeList:
        try container.encode("subscribe_list", forKey: .type)

      case let .subscribeSession(sessionId):
        try container.encode("subscribe_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .unsubscribeSession(sessionId):
        try container.encode("unsubscribe_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .createSession(provider, cwd, model, approvalPolicy, sandboxMode):
        try container.encode("create_session", forKey: .type)
        try container.encode(provider, forKey: .provider)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)

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

      case let .approveTool(sessionId, requestId, decision):
        try container.encode("approve_tool", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(decision, forKey: .decision)

      case let .answerQuestion(sessionId, requestId, answer):
        try container.encode("answer_question", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(answer, forKey: .answer)

      case let .interruptSession(sessionId):
        try container.encode("interrupt_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .endSession(sessionId):
        try container.encode("end_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .updateSessionConfig(sessionId, approvalPolicy, sandboxMode):
        try container.encode("update_session_config", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)

      case let .renameSession(sessionId, name):
        try container.encode("rename_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(name, forKey: .name)

      case let .resumeSession(sessionId):
        try container.encode("resume_session", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .listApprovals(sessionId, limit):
        try container.encode("list_approvals", forKey: .type)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(limit, forKey: .limit)

      case let .deleteApproval(approvalId):
        try container.encode("delete_approval", forKey: .type)
        try container.encode(approvalId, forKey: .approvalId)

      case .listModels:
        try container.encode("list_models", forKey: .type)

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

      case let .steerTurn(sessionId, content):
        try container.encode("steer_turn", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(content, forKey: .content)

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

      case let .forkSession(sourceSessionId, nthUserMessage, model, approvalPolicy, sandboxMode, cwd):
        try container.encode("fork_session", forKey: .type)
        try container.encode(sourceSessionId, forKey: .sourceSessionId)
        try container.encodeIfPresent(nthUserMessage, forKey: .nthUserMessage)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
        try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)
        try container.encodeIfPresent(cwd, forKey: .cwd)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
      case "subscribe_list":
        self = .subscribeList
      case "subscribe_session":
        self = try .subscribeSession(sessionId: container.decode(String.self, forKey: .sessionId))
      case "unsubscribe_session":
        self = try .unsubscribeSession(sessionId: container.decode(String.self, forKey: .sessionId))
      case "create_session":
        self = try .createSession(
          provider: container.decode(ServerProvider.self, forKey: .provider),
          cwd: container.decode(String.self, forKey: .cwd),
          model: container.decodeIfPresent(String.self, forKey: .model),
          approvalPolicy: container.decodeIfPresent(String.self, forKey: .approvalPolicy),
          sandboxMode: container.decodeIfPresent(String.self, forKey: .sandboxMode)
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
          decision: container.decode(String.self, forKey: .decision)
        )
      case "answer_question":
        self = try .answerQuestion(
          sessionId: container.decode(String.self, forKey: .sessionId),
          requestId: container.decode(String.self, forKey: .requestId),
          answer: container.decode(String.self, forKey: .answer)
        )
      case "interrupt_session":
        self = try .interruptSession(sessionId: container.decode(String.self, forKey: .sessionId))
      case "end_session":
        self = try .endSession(sessionId: container.decode(String.self, forKey: .sessionId))
      case "update_session_config":
        self = try .updateSessionConfig(
          sessionId: container.decode(String.self, forKey: .sessionId),
          approvalPolicy: container.decodeIfPresent(String.self, forKey: .approvalPolicy),
          sandboxMode: container.decodeIfPresent(String.self, forKey: .sandboxMode)
        )
      case "rename_session":
        self = try .renameSession(
          sessionId: container.decode(String.self, forKey: .sessionId),
          name: container.decodeIfPresent(String.self, forKey: .name)
        )
      case "resume_session":
        self = try .resumeSession(sessionId: container.decode(String.self, forKey: .sessionId))
      case "list_approvals":
        self = try .listApprovals(
          sessionId: container.decodeIfPresent(String.self, forKey: .sessionId),
          limit: container.decodeIfPresent(Int.self, forKey: .limit)
        )
      case "delete_approval":
        self = try .deleteApproval(approvalId: container.decode(Int64.self, forKey: .approvalId))
      case "list_models":
        self = .listModels
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
          content: container.decode(String.self, forKey: .content)
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
          cwd: container.decodeIfPresent(String.self, forKey: .cwd)
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
