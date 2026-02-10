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
  case sendMessage(sessionId: String, content: String, model: String? = nil, effort: String? = nil)
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

  enum CodingKeys: String, CodingKey {
    case type
    case sessionId = "session_id"
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

      case let .sendMessage(sessionId, content, model, effort):
        try container.encode("send_message", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(effort, forKey: .effort)

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
          effort: container.decodeIfPresent(String.self, forKey: .effort)
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
