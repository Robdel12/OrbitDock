//
//  CodexProtocol.swift
//  OrbitDock
//
//  Type-safe definitions for the Codex app-server JSON-RPC protocol.
//  Based on codex-rs/app-server-protocol.
//

import Foundation

// MARK: - JSON-RPC Base Types

struct JSONRPCRequest<Params: Encodable>: Encodable {
  let method: String
  let id: Int
  let params: Params?

  init(method: String, id: Int, params: Params? = nil) {
    self.method = method
    self.id = id
    self.params = params
  }
}

struct JSONRPCResponse<Result: Decodable>: Decodable {
  let id: Int?
  let result: Result?
  let error: JSONRPCError?
}

struct JSONRPCError: Decodable, Error, LocalizedError {
  let code: Int
  let message: String
  let data: AnyCodable?

  var errorDescription: String? { message }
}

struct JSONRPCNotification: Decodable {
  let method: String
  let params: AnyCodable?
}

// MARK: - Initialize

struct ClientInfo: Codable {
  let name: String
  let title: String
  let version: String
}

struct InitializeParams: Codable {
  let clientInfo: ClientInfo
  let capabilities: ClientCapabilities?

  init(clientInfo: ClientInfo, capabilities: ClientCapabilities? = nil) {
    self.clientInfo = clientInfo
    self.capabilities = capabilities
  }
}

struct ClientCapabilities: Codable {
  let experimentalApi: Bool?

  init(experimentalApi: Bool? = nil) {
    self.experimentalApi = experimentalApi
  }

  enum CodingKeys: String, CodingKey {
    case experimentalApi = "experimental_api"
  }
}

struct InitializeResult: Decodable {
  let userAgent: String?

  enum CodingKeys: String, CodingKey {
    case userAgent = "user_agent"
  }
}

// MARK: - Thread Types

struct ThreadStartParams: Codable {
  let cwd: String
  let model: String?
  let approvalPolicy: String?
  let sandboxPolicy: SandboxPolicy?

  init(cwd: String, model: String? = nil, approvalPolicy: String? = "untrusted", sandboxPolicy: SandboxPolicy? = nil) {
    self.cwd = cwd
    self.model = model
    self.approvalPolicy = approvalPolicy
    self.sandboxPolicy = sandboxPolicy
  }

  enum CodingKeys: String, CodingKey {
    case cwd
    case model
    case approvalPolicy = "approval_policy"
    case sandboxPolicy = "sandbox_policy"
  }
}

struct SandboxPolicy: Codable {
  let type: String // "read_only", "workspace_write", "danger_full_access"
  let writableRoots: [String]?
  let networkAccess: Bool?

  init(type: String = "workspace-write", writableRoots: [String]? = nil, networkAccess: Bool? = nil) {
    self.type = type
    self.writableRoots = writableRoots
    self.networkAccess = networkAccess
  }

  enum CodingKeys: String, CodingKey {
    case type
    case writableRoots = "writable_roots"
    case networkAccess = "network_access"
  }
}

struct ThreadStartResult: Decodable {
  let thread: ThreadInfo

  var threadId: String { thread.id }
}

struct ThreadInfo: Decodable {
  let id: String
  let path: String?
  let preview: String?
  let modelProvider: String?
  let createdAt: Int?
  let updatedAt: Int?
}

struct ThreadResumeParams: Codable {
  let threadId: String
  let cwd: String?
  let model: String?
  let approvalPolicy: String?

  init(threadId: String, cwd: String? = nil, model: String? = nil, approvalPolicy: String? = nil) {
    self.threadId = threadId
    self.cwd = cwd
    self.model = model
    self.approvalPolicy = approvalPolicy
  }
  // API uses camelCase - no CodingKeys needed
}

struct ThreadResumeResult: Decodable {
  let thread: ThreadInfo

  var threadId: String { thread.id }
}

struct ThreadListParams: Codable {
  let limit: Int?
  let cursor: String?
  let includeArchived: Bool?

  init(limit: Int? = 50, cursor: String? = nil, includeArchived: Bool? = false) {
    self.limit = limit
    self.cursor = cursor
    self.includeArchived = includeArchived
  }

  enum CodingKeys: String, CodingKey {
    case limit
    case cursor
    case includeArchived = "include_archived"
  }
}

struct ThreadListResult: Decodable {
  let data: [ThreadSummary]
  let nextCursor: String?

  // Convenience alias
  var threads: [ThreadSummary] { data }

  enum CodingKeys: String, CodingKey {
    case data
    case nextCursor = "next_cursor"
  }
}

struct ThreadSummary: Decodable, Identifiable {
  let id: String
  let name: String?
  let cwd: String?
  let model: String?
  let createdAt: String?
  let updatedAt: String?
  let isArchived: Bool?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case cwd
    case model
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case isArchived = "is_archived"
  }
}

struct ThreadReadParams: Codable {
  let threadId: String
  let includeTurns: Bool?

  init(threadId: String, includeTurns: Bool? = nil) {
    self.threadId = threadId
    self.includeTurns = includeTurns
  }
  // API uses camelCase - no CodingKeys needed
}

struct ThreadReadResult: Decodable {
  let thread: ThreadDetail

  enum CodingKeys: String, CodingKey {
    case thread
  }
}

struct ThreadDetail: Decodable {
  let id: String
  let name: String?
  let cwd: String?
  let model: String?
  let turns: [Turn]?
}

// MARK: - Turn Types

struct Turn: Decodable, Identifiable {
  let id: String
  let status: String? // "in_progress", "completed", "aborted"
  let items: [TurnItem]?
}

struct TurnItem: Decodable, Identifiable {
  let id: String
  let type: String
  let content: AnyCodable?
}

struct TurnStartParams: Codable {
  let threadId: String
  let input: [UserInputItem]

  // API expects camelCase: threadId, not thread_id
  // API expects "input" array, not "items"
}

struct UserInputItem: Codable {
  let type: String
  let text: String?

  init(text: String) {
    self.type = "text"
    self.text = text
  }
}

struct TurnStartResult: Decodable {
  let turn: TurnResult

  var id: String { turn.id }
}

struct TurnResult: Decodable {
  let id: String
  let status: String?
  let items: [TurnItem]?
  let error: CodexTurnError?
}

struct TurnInterruptParams: Codable {
  let threadId: String
  let turnId: String?
  // API expects camelCase: threadId, turnId
}

// MARK: - Submission Types (sent via stdin as JSONL)

protocol CodexSubmission: Encodable {
  var type: String { get }
}

struct InterruptSubmission: CodexSubmission, Encodable {
  let type = "interrupt"
}

struct ExecApprovalSubmission: CodexSubmission, Encodable {
  let type = "exec_approval"
  let id: String
  let decision: ApprovalDecision
}

struct PatchApprovalSubmission: CodexSubmission, Encodable {
  let type = "patch_approval"
  let id: String
  let decision: ApprovalDecision
}

struct ApprovalDecision: Codable {
  let type: String // "approve", "reject", "always_approve"

  static let approve = ApprovalDecision(type: "approve")
  static let reject = ApprovalDecision(type: "reject")
  static let alwaysApprove = ApprovalDecision(type: "always_approve")
}

struct UserInputAnswerSubmission: CodexSubmission, Encodable {
  let type = "user_input_answer"
  let id: String
  let response: UserInputResponse
}

struct UserInputResponse: Codable {
  let answers: [String: String]
}

// MARK: - Event Types (notifications from app-server)

enum CodexServerEvent {
  // Turn lifecycle
  case turnStarted(TurnStartedEvent)
  case turnCompleted(TurnCompletedEvent)
  case turnAborted(TurnAbortedEvent)

  // Items
  case itemCreated(ItemCreatedEvent)
  case itemUpdated(ItemUpdatedEvent)

  // Approvals
  case execApprovalRequest(ExecApprovalRequestEvent)
  case patchApprovalRequest(PatchApprovalRequestEvent)

  // User input
  case userInputRequest(UserInputRequestEvent)
  case elicitationRequest(ElicitationRequestEvent)

  // Session
  case sessionConfigured(SessionConfiguredEvent)
  case threadNameUpdated(ThreadNameUpdatedEvent)

  // Usage tracking
  case tokenUsageUpdated(TokenUsageEvent)
  case rateLimitsUpdated(RateLimitsEvent)

  // MCP lifecycle
  case mcpStartupUpdate(MCPStartupEvent)
  case mcpStartupComplete(MCPStartupEvent)

  // Errors
  case error(CodexErrorEvent)

  // Ignored events (streaming deltas, legacy duplicates)
  case ignored

  // Unknown
  case unknown(method: String, params: AnyCodable?)
}

struct TurnStartedEvent: Decodable {
  let threadId: String?
  let turn: TurnResult?

  // API uses camelCase: threadId (not thread_id)
  var turnId: String? { turn?.id }
}

struct TurnCompletedEvent: Decodable {
  let threadId: String?
  let turn: TurnResult?

  // API uses camelCase: threadId (not thread_id)
  var turnId: String? { turn?.id }
  var error: CodexTurnError? { turn?.error }
}

struct CodexTurnError: Decodable {
  let code: String?
  let message: String?
}

struct TurnAbortedEvent: Decodable {
  let threadId: String?
  let turn: TurnResult?

  // API uses camelCase
  var turnId: String? { turn?.id }
}

struct ItemCreatedEvent: Decodable {
  let threadId: String?
  let turnId: String?
  let item: ThreadItem
  // API uses camelCase: threadId, turnId (not snake_case)
}

struct ItemUpdatedEvent: Decodable {
  let threadId: String?
  let turnId: String?
  let item: ThreadItem
  // API uses camelCase: threadId, turnId (not snake_case)
}

struct ThreadItem: Decodable {
  let id: String
  let type: String
  let status: String?

  // agentMessage: has "text" field
  let text: String?

  // userMessage: has "content" array
  let content: [ContentBlock]?

  // reasoning: has "summary" array
  let summary: [String]?

  // commandExecution fields
  let command: String?
  let cwd: String?
  let exitCode: Int?
  let aggregatedOutput: String?

  // mcpToolCall fields
  let server: String?
  let tool: String?
  let arguments: AnyCodable?
  let result: AnyCodable?
  let error: AnyCodable?

  // fileChange fields
  let changes: [FileChange]?

  // webSearch fields
  let query: String?
  let searchResults: String?

  // API uses camelCase throughout

  // Computed properties for event handler compatibility
  var name: String? {
    // For mcpToolCall, use tool; for commandExecution, use command
    tool ?? command
  }

  var callId: String? {
    // The item id serves as the call id
    id
  }

  var output: String? {
    // For commandExecution, use aggregatedOutput
    // For mcpToolCall, stringify result
    if let output = aggregatedOutput {
      return output
    }
    if let result, let str = result.string {
      return str
    }
    return nil
  }

  var summaryText: [String]? {
    summary
  }

  var toolInput: String? {
    // Stringify arguments for display
    guard let args = arguments else { return nil }
    if let dict = args.dictionary,
       let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
       let str = String(data: data, encoding: .utf8)
    {
      return str
    }
    return nil
  }
}

struct FileChange: Decodable {
  let path: String?
  let kind: String?
  let diff: String?
}

struct ContentBlock: Decodable {
  let type: String
  let text: String?
}

struct ExecApprovalRequestEvent: Decodable {
  let id: String
  let command: CommandInfo?
  let cwd: String?

  struct CommandInfo: Decodable {
    let command: [String]?
    let workdir: String?
  }
}

struct PatchApprovalRequestEvent: Decodable {
  let id: String
  let path: String?
  let patch: String?
  let autoApprove: Bool?

  enum CodingKeys: String, CodingKey {
    case id
    case path
    case patch
    case autoApprove = "auto_approve"
  }
}

struct UserInputRequestEvent: Decodable {
  let id: String
  let questions: [UserInputQuestion]?
}

struct UserInputQuestion: Decodable {
  let question: String?
  let header: String?
  let options: [UserInputOption]?
  let multiSelect: Bool?

  enum CodingKeys: String, CodingKey {
    case question
    case header
    case options
    case multiSelect = "multi_select"
  }
}

struct UserInputOption: Decodable {
  let label: String
  let description: String?
}

struct ElicitationRequestEvent: Decodable {
  let serverName: String?
  let requestId: String?
  let message: String?

  enum CodingKeys: String, CodingKey {
    case serverName = "server_name"
    case requestId = "request_id"
    case message
  }
}

struct SessionConfiguredEvent: Decodable {
  let model: String?
  let cwd: String?
}

struct ThreadNameUpdatedEvent: Decodable {
  let threadId: String?
  let threadName: String?
  // API uses camelCase
}

struct CodexErrorEvent: Decodable {
  let code: String?
  let message: String?
  let httpStatusCode: Int?

  enum CodingKeys: String, CodingKey {
    case code
    case message
    case httpStatusCode = "http_status_code"
  }
}

// MARK: - Token Usage Events

struct TokenUsageEvent: Decodable {
  let threadId: String?
  let turnId: String?
  let tokenUsage: TokenUsageData?

  // Nested token usage data
  struct TokenUsageData: Decodable {
    let total: TokenCounts?
    let last: TokenCounts?
    let modelContextWindow: Int?
  }

  // Individual token counts
  struct TokenCounts: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let reasoningOutputTokens: Int?
    let cachedInputTokens: Int?
  }

  // Convenience accessors - cumulative session totals
  var totalInputTokens: Int? { tokenUsage?.total?.inputTokens }
  var totalOutputTokens: Int? { tokenUsage?.total?.outputTokens }
  var totalCachedTokens: Int? { tokenUsage?.total?.cachedInputTokens }
  var contextWindow: Int? { tokenUsage?.modelContextWindow }

  // Last turn only
  var lastInputTokens: Int? { tokenUsage?.last?.inputTokens }
  var lastOutputTokens: Int? { tokenUsage?.last?.outputTokens }
  var lastCachedTokens: Int? { tokenUsage?.last?.cachedInputTokens }
}

struct RateLimitsEvent: Decodable {
  let threadId: String?
  let rateLimits: CodexRateLimits?
}

// MARK: - MCP Startup Events

struct MCPStartupEvent: Decodable {
  let server: String?
  let status: MCPServerStatus?

  struct MCPServerStatus: Decodable {
    let state: String?  // "starting", "connected", "failed"
    let error: String?
  }

  // Handle nested msg structure from codex/event format
  struct LegacyParams: Decodable {
    let msg: MCPStartupMessage?
    let conversationId: String?

    struct MCPStartupMessage: Decodable {
      let type: String?
      let server: String?
      let status: MCPServerStatus?
    }
  }
}

// MARK: - Rate Limits (for usage display)

struct RateLimitsResult: Decodable {
  let rateLimits: CodexRateLimits?

  enum CodingKeys: String, CodingKey {
    case rateLimits = "rate_limits"
  }
}

struct CodexRateLimits: Decodable {
  let primary: CodexRateLimitWindow?
  let secondary: CodexRateLimitWindow?
}

struct CodexRateLimitWindow: Decodable {
  let usedPercent: Double?
  let windowDurationMins: Int?
  let resetsAt: Double?

  enum CodingKeys: String, CodingKey {
    case usedPercent = "used_percent"
    case windowDurationMins = "window_duration_mins"
    case resetsAt = "resets_at"
  }
}

// MARK: - Account

struct AccountReadParams: Codable {
  let refreshToken: Bool?

  init(refreshToken: Bool? = false) {
    self.refreshToken = refreshToken
  }

  enum CodingKeys: String, CodingKey {
    case refreshToken = "refresh_token"
  }
}

struct AccountReadResult: Decodable {
  let account: AccountInfo?
}

struct AccountInfo: Decodable {
  let type: String? // "chatgpt", "apiKey"
  let email: String?
  let name: String?
}

// MARK: - Models

struct ModelListResult: Decodable {
  let models: [CodexModel]
}

struct CodexModel: Decodable, Identifiable {
  let id: String
  let model: String?
  let displayName: String?
  let description: String?
  let isDefault: Bool?

  enum CodingKeys: String, CodingKey {
    case id
    case model
    case displayName = "display_name"
    case description
    case isDefault = "is_default"
  }
}

// MARK: - Helper: AnyCodable for dynamic JSON

struct AnyCodable: Codable {
  let value: Any

  init(_ value: Any) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      value = NSNull()
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let double = try? container.decode(Double.self) {
      value = double
    } else if let string = try? container.decode(String.self) {
      value = string
    } else if let array = try? container.decode([AnyCodable].self) {
      value = array.map(\.value)
    } else if let dict = try? container.decode([String: AnyCodable].self) {
      value = dict.mapValues(\.value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch value {
      case is NSNull:
        try container.encodeNil()
      case let bool as Bool:
        try container.encode(bool)
      case let int as Int:
        try container.encode(int)
      case let double as Double:
        try container.encode(double)
      case let string as String:
        try container.encode(string)
      case let array as [Any]:
        try container.encode(array.map { AnyCodable($0) })
      case let dict as [String: Any]:
        try container.encode(dict.mapValues { AnyCodable($0) })
      default:
        throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Unsupported type"))
    }
  }

  var dictionary: [String: Any]? {
    value as? [String: Any]
  }

  var array: [Any]? {
    value as? [Any]
  }

  var string: String? {
    value as? String
  }

  var int: Int? {
    value as? Int
  }

  var double: Double? {
    value as? Double
  }

  var bool: Bool? {
    value as? Bool
  }
}

// MARK: - Event Parsing

extension CodexServerEvent {
  static func parse(method: String, params: AnyCodable?) -> CodexServerEvent {
    let decoder = JSONDecoder()

    // Helper to decode params
    func decode<T: Decodable>(_ type: T.Type) -> T? {
      guard let params,
            let data = try? JSONSerialization.data(withJSONObject: params.value)
      else { return nil }
      return try? decoder.decode(type, from: data)
    }

    switch method {
      // === IGNORED EVENTS (streaming deltas, high frequency noise) ===
      case "codex/event/agent_message_delta",
           "codex/event/agent_message_content_delta",
           "item/agentMessage/delta",
           "codex/event/reasoning_delta",
           "codex/event/reasoning_content_delta",
           "codex/event/agent_reasoning_delta",
           "item/reasoning/delta",
           "item/reasoning/summaryTextDelta",
           "item/reasoning/summaryPartAdded",
           "codex/event/agent_reasoning",
           "codex/event/agent_reasoning_section_break",
           "codex/event/web_search_begin",
           "codex/event/web_search_end":
        return .ignored

      // === TURN LIFECYCLE ===
      case "turn/started":
        if let event = decode(TurnStartedEvent.self) {
          return .turnStarted(event)
        }

      case "turn/completed":
        if let event = decode(TurnCompletedEvent.self) {
          return .turnCompleted(event)
        }

      case "turn/aborted":
        if let event = decode(TurnAbortedEvent.self) {
          return .turnAborted(event)
        }

      // Legacy turn events (route to same handlers)
      case "codex/event/task_started":
        return .ignored  // Duplicate of turn/started

      case "codex/event/task_complete":
        return .ignored  // Duplicate of turn/completed

      // === ITEM LIFECYCLE ===
      case "item/started":
        if let event = decode(ItemCreatedEvent.self) {
          return .itemCreated(event)
        }

      case "item/completed":
        if let event = decode(ItemUpdatedEvent.self) {
          return .itemUpdated(event)
        }

      // Legacy item events (duplicates)
      case "codex/event/item_started",
           "codex/event/item_completed",
           "codex/event/user_message",
           "codex/event/agent_message",
           "codex/event/exec_command_begin",
           "codex/event/exec_command_end":
        return .ignored  // Handled by item/started and item/completed

      // === APPROVALS (JSON-RPC requests, not notifications) ===
      case "item/commandExecution/requestApproval":
        if let event = decode(ExecApprovalRequestEvent.self) {
          return .execApprovalRequest(event)
        }

      case "item/fileChange/requestApproval":
        if let event = decode(PatchApprovalRequestEvent.self) {
          return .patchApprovalRequest(event)
        }

      case "tool/requestUserInput":
        if let event = decode(UserInputRequestEvent.self) {
          return .userInputRequest(event)
        }

      case "elicitation_request":
        if let event = decode(ElicitationRequestEvent.self) {
          return .elicitationRequest(event)
        }

      // === SESSION ===
      case "session_configured":
        if let event = decode(SessionConfiguredEvent.self) {
          return .sessionConfigured(event)
        }

      case "thread/name/updated":
        if let event = decode(ThreadNameUpdatedEvent.self) {
          return .threadNameUpdated(event)
        }

      // === TOKEN USAGE & RATE LIMITS ===
      case "thread/tokenUsage/updated":
        if let event = decode(TokenUsageEvent.self) {
          return .tokenUsageUpdated(event)
        }

      case "account/rateLimits/updated":
        if let event = decode(RateLimitsEvent.self) {
          return .rateLimitsUpdated(event)
        }

      // Legacy token count (duplicate)
      case "codex/event/token_count":
        return .ignored  // Handled by thread/tokenUsage/updated

      // === MCP LIFECYCLE ===
      case "codex/event/mcp_startup_update":
        if let legacyParams = decode(MCPStartupEvent.LegacyParams.self),
           let msg = legacyParams.msg
        {
          let event = MCPStartupEvent(server: msg.server, status: msg.status)
          return .mcpStartupUpdate(event)
        }

      case "codex/event/mcp_startup_complete":
        if let legacyParams = decode(MCPStartupEvent.LegacyParams.self),
           let msg = legacyParams.msg
        {
          let event = MCPStartupEvent(server: msg.server, status: msg.status)
          return .mcpStartupComplete(event)
        }

      // === ERRORS ===
      case "error":
        if let event = decode(CodexErrorEvent.self) {
          return .error(event)
        }

      default:
        break
    }

    return .unknown(method: method, params: params)
  }
}

// MARK: - Error Types

enum CodexClientError: LocalizedError {
  case notInstalled
  case connectionFailed(underlying: Error)
  case notConnected
  case requestFailed(code: Int, message: String)
  case processTerminated
  case encodingFailed
  case decodingFailed(underlying: Error)
  case timeout
  case notLoggedIn
  case apiKeyMode

  var errorDescription: String? {
    switch self {
      case .notInstalled:
        "Codex CLI is not installed"
      case let .connectionFailed(error):
        "Failed to connect: \(error.localizedDescription)"
      case .notConnected:
        "Not connected to Codex app-server"
      case let .requestFailed(code, message):
        "Request failed (\(code)): \(message)"
      case .processTerminated:
        "Codex app-server process terminated unexpectedly"
      case .encodingFailed:
        "Failed to encode request"
      case let .decodingFailed(error):
        "Failed to decode response: \(error.localizedDescription)"
      case .timeout:
        "Request timed out"
      case .notLoggedIn:
        "Not logged in to Codex"
      case .apiKeyMode:
        "Codex is using API key mode"
    }
  }

  var recoverySuggestion: String? {
    switch self {
      case .notInstalled:
        "Install Codex CLI with: npm install -g @openai/codex"
      case .notLoggedIn:
        "Run 'codex auth login' to authenticate"
      case .processTerminated:
        "Reconnecting automatically..."
      default:
        nil
    }
  }
}
