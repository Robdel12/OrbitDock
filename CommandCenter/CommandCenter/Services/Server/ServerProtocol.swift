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
  let toolInput: String?  // JSON string
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
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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

// MARK: - Session Summary

struct ServerSessionSummary: Codable, Identifiable {
  let id: String
  let provider: ServerProvider
  let projectPath: String
  let projectName: String?
  let model: String?
  let customName: String?
  let status: ServerSessionStatus
  let workStatus: ServerWorkStatus
  let hasPendingApproval: Bool
  let startedAt: String?
  let lastActivityAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case projectPath = "project_path"
    case projectName = "project_name"
    case model
    case customName = "custom_name"
    case status
    case workStatus = "work_status"
    case hasPendingApproval = "has_pending_approval"
    case startedAt = "started_at"
    case lastActivityAt = "last_activity_at"
  }
}

// MARK: - Session State

struct ServerSessionState: Codable, Identifiable {
  let id: String
  let provider: ServerProvider
  let projectPath: String
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
  let startedAt: String?
  let lastActivityAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case projectPath = "project_path"
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
  let lastActivityAt: String?

  enum CodingKeys: String, CodingKey {
    case status
    case workStatus = "work_status"
    case pendingApproval = "pending_approval"
    case tokenUsage = "token_usage"
    case currentDiff = "current_diff"
    case currentPlan = "current_plan"
    case customName = "custom_name"
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
    case .sessionsList(let sessions):
      try container.encode("sessions_list", forKey: .type)
      try container.encode(sessions, forKey: .sessions)

    case .sessionSnapshot(let session):
      try container.encode("session_snapshot", forKey: .type)
      try container.encode(session, forKey: .session)

    case .sessionDelta(let sessionId, let changes):
      try container.encode("session_delta", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encode(changes, forKey: .changes)

    case .messageAppended(let sessionId, let message):
      try container.encode("message_appended", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encode(message, forKey: .message)

    case .messageUpdated(let sessionId, let messageId, let changes):
      try container.encode("message_updated", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encode(messageId, forKey: .messageId)
      try container.encode(changes, forKey: .changes)

    case .approvalRequested(let sessionId, let request):
      try container.encode("approval_requested", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encode(request, forKey: .request)

    case .tokensUpdated(let sessionId, let usage):
      try container.encode("tokens_updated", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encode(usage, forKey: .usage)

    case .sessionCreated(let session):
      try container.encode("session_created", forKey: .type)
      try container.encode(session, forKey: .session)

    case .sessionEnded(let sessionId, let reason):
      try container.encode("session_ended", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encode(reason, forKey: .reason)

    case .error(let code, let message, let sessionId):
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
  case createSession(provider: ServerProvider, cwd: String, model: String?, approvalPolicy: String?, sandboxMode: String?)
  case sendMessage(sessionId: String, content: String)
  case approveTool(sessionId: String, requestId: String, decision: String)
  case answerQuestion(sessionId: String, requestId: String, answer: String)
  case interruptSession(sessionId: String)
  case endSession(sessionId: String)
  case updateSessionConfig(sessionId: String, approvalPolicy: String?, sandboxMode: String?)
  case renameSession(sessionId: String, name: String?)
  case resumeSession(sessionId: String)

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
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .subscribeList:
      try container.encode("subscribe_list", forKey: .type)

    case .subscribeSession(let sessionId):
      try container.encode("subscribe_session", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)

    case .unsubscribeSession(let sessionId):
      try container.encode("unsubscribe_session", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)

    case .createSession(let provider, let cwd, let model, let approvalPolicy, let sandboxMode):
      try container.encode("create_session", forKey: .type)
      try container.encode(provider, forKey: .provider)
      try container.encode(cwd, forKey: .cwd)
      try container.encodeIfPresent(model, forKey: .model)
      try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
      try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)

    case .sendMessage(let sessionId, let content):
      try container.encode("send_message", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encode(content, forKey: .content)

    case .approveTool(let sessionId, let requestId, let decision):
      try container.encode("approve_tool", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encode(requestId, forKey: .requestId)
      try container.encode(decision, forKey: .decision)

    case .answerQuestion(let sessionId, let requestId, let answer):
      try container.encode("answer_question", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encode(requestId, forKey: .requestId)
      try container.encode(answer, forKey: .answer)

    case .interruptSession(let sessionId):
      try container.encode("interrupt_session", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)

    case .endSession(let sessionId):
      try container.encode("end_session", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)

    case .updateSessionConfig(let sessionId, let approvalPolicy, let sandboxMode):
      try container.encode("update_session_config", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encodeIfPresent(approvalPolicy, forKey: .approvalPolicy)
      try container.encodeIfPresent(sandboxMode, forKey: .sandboxMode)

    case .renameSession(let sessionId, let name):
      try container.encode("rename_session", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
      try container.encodeIfPresent(name, forKey: .name)

    case .resumeSession(let sessionId):
      try container.encode("resume_session", forKey: .type)
      try container.encode(sessionId, forKey: .sessionId)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "subscribe_list":
      self = .subscribeList
    case "subscribe_session":
      self = .subscribeSession(sessionId: try container.decode(String.self, forKey: .sessionId))
    case "unsubscribe_session":
      self = .unsubscribeSession(sessionId: try container.decode(String.self, forKey: .sessionId))
    case "create_session":
      self = .createSession(
        provider: try container.decode(ServerProvider.self, forKey: .provider),
        cwd: try container.decode(String.self, forKey: .cwd),
        model: try container.decodeIfPresent(String.self, forKey: .model),
        approvalPolicy: try container.decodeIfPresent(String.self, forKey: .approvalPolicy),
        sandboxMode: try container.decodeIfPresent(String.self, forKey: .sandboxMode)
      )
    case "send_message":
      self = .sendMessage(
        sessionId: try container.decode(String.self, forKey: .sessionId),
        content: try container.decode(String.self, forKey: .content)
      )
    case "approve_tool":
      self = .approveTool(
        sessionId: try container.decode(String.self, forKey: .sessionId),
        requestId: try container.decode(String.self, forKey: .requestId),
        decision: try container.decode(String.self, forKey: .decision)
      )
    case "answer_question":
      self = .answerQuestion(
        sessionId: try container.decode(String.self, forKey: .sessionId),
        requestId: try container.decode(String.self, forKey: .requestId),
        answer: try container.decode(String.self, forKey: .answer)
      )
    case "interrupt_session":
      self = .interruptSession(sessionId: try container.decode(String.self, forKey: .sessionId))
    case "end_session":
      self = .endSession(sessionId: try container.decode(String.self, forKey: .sessionId))
    case "update_session_config":
      self = .updateSessionConfig(
        sessionId: try container.decode(String.self, forKey: .sessionId),
        approvalPolicy: try container.decodeIfPresent(String.self, forKey: .approvalPolicy),
        sandboxMode: try container.decodeIfPresent(String.self, forKey: .sandboxMode)
      )
    case "rename_session":
      self = .renameSession(
        sessionId: try container.decode(String.self, forKey: .sessionId),
        name: try container.decodeIfPresent(String.self, forKey: .name)
      )
    case "resume_session":
      self = .resumeSession(sessionId: try container.decode(String.self, forKey: .sessionId))
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

