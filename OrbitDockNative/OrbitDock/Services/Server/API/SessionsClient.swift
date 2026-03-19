import Foundation

struct SessionsClient: Sendable {
  enum OptionalStringPatch: Encodable, Sendable {
    case set(String)
    case clear

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
        case let .set(value):
          try container.encode(value)
        case .clear:
          try container.encodeNil()
      }
    }
  }

  enum OptionalBoolPatch: Encodable, Sendable {
    case set(Bool)
    case clear

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
        case let .set(value):
          try container.encode(value)
        case .clear:
          try container.encodeNil()
      }
    }
  }

  struct SessionsListResponse: Decodable {
    let sessions: [ServerSessionListItem]
  }

  struct SessionSnapshotResponse: Decodable {
    let session: ServerSessionState
  }

  struct CreateSessionRequest: Encodable, Sendable {
    let provider: String
    let cwd: String
    var model: String?
    var approvalPolicy: String?
    var sandboxMode: String?
    var permissionMode: String?
    var collaborationMode: String?
    var multiAgent: Bool?
    var personality: String?
    var serviceTier: String?
    var developerInstructions: String?
    var allowedTools: [String] = []
    var disallowedTools: [String] = []
    var effort: String?
    var allowBypassPermissions: Bool?
    var codexConfigSource: ServerCodexConfigSource?
  }

  struct CodexPreferencesResponse: Decodable {
    let defaultConfigSource: ServerCodexConfigSource

    enum CodingKeys: String, CodingKey {
      case defaultConfigSource = "default_config_source"
    }
  }

  struct UpdateCodexPreferencesRequest: Encodable {
    let defaultConfigSource: ServerCodexConfigSource

    enum CodingKeys: String, CodingKey {
      case defaultConfigSource = "default_config_source"
    }
  }

  struct CodexInspectRequest: Encodable {
    let cwd: String
    var codexConfigSource: ServerCodexConfigSource?
    var model: String?
    var approvalPolicy: String?
    var sandboxMode: String?
    var collaborationMode: String?
    var multiAgent: Bool?
    var personality: String?
    var serviceTier: String?
    var developerInstructions: String?
    var effort: String?
  }

  struct CodexInspectorResponse: Decodable {
    let effectiveSettings: CodexEffectiveSettings
    let origins: [String: CodexInspectorOrigin]
    let layers: [CodexInspectorLayer]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
      case effectiveSettings = "effective_settings"
      case origins
      case layers
      case warnings
    }
  }

  struct CodexEffectiveSettings: Decodable {
    let configSource: ServerCodexConfigSource
    let model: String?
    let approvalPolicy: String?
    let sandboxMode: String?
    let collaborationMode: String?
    let multiAgent: Bool?
    let personality: String?
    let serviceTier: String?
    let developerInstructions: String?
    let effort: String?

    enum CodingKeys: String, CodingKey {
      case configSource = "config_source"
      case model
      case approvalPolicy = "approval_policy"
      case sandboxMode = "sandbox_mode"
      case collaborationMode = "collaboration_mode"
      case multiAgent = "multi_agent"
      case personality
      case serviceTier = "service_tier"
      case developerInstructions = "developer_instructions"
      case effort
    }
  }

  struct CodexInspectorOrigin: Decodable {
    let sourceKind: String
    let path: String?
    let version: String

    enum CodingKeys: String, CodingKey {
      case sourceKind = "source_kind"
      case path
      case version
    }
  }

  struct CodexInspectorLayer: Decodable, Identifiable {
    let sourceKind: String
    let path: String?
    let version: String
    let config: AnyCodable
    let disabledReason: String?

    var id: String { [sourceKind, path ?? "none", version].joined(separator: "|") }

    enum CodingKeys: String, CodingKey {
      case sourceKind = "source_kind"
      case path
      case version
      case config
      case disabledReason = "disabled_reason"
    }
  }

  struct CreateSessionResponse: Decodable {
    let sessionId: String
    let session: ServerSessionSummary

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case session
    }
  }

  struct ResumeSessionResponse: Decodable {
    let sessionId: String
    let session: ServerSessionSummary

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case session
    }
  }

  struct TakeoverRequest: Encodable {
    var model: String?
    var approvalPolicy: String?
    var sandboxMode: String?
    var permissionMode: String?
    var collaborationMode: String?
    var multiAgent: Bool?
    var personality: String?
    var serviceTier: String?
    var developerInstructions: String?
    var allowedTools: [String] = []
    var disallowedTools: [String] = []
  }

  struct TakeoverResponse: Decodable {
    let sessionId: String
    let accepted: Bool

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case accepted
    }
  }

  struct UpdateSessionConfigRequest: Encodable {
    var approvalPolicy: String?
    var sandboxMode: String?
    var permissionMode: String?
    var collaborationMode: String?
    var multiAgent: Bool?
    var personality: String?
    var serviceTier: String?
    var developerInstructions: String?
  }

  struct UpdateCodexSessionOverridesRequest: Encodable {
    var collaborationMode: OptionalStringPatch?
    var multiAgent: OptionalBoolPatch?
    var personality: OptionalStringPatch?
    var serviceTier: OptionalStringPatch?
    var developerInstructions: OptionalStringPatch?

    enum CodingKeys: String, CodingKey {
      case collaborationMode = "collaboration_mode"
      case multiAgent = "multi_agent"
      case personality
      case serviceTier = "service_tier"
      case developerInstructions = "developer_instructions"
    }
  }

  struct ForkRequest: Encodable {
    var nthUserMessage: UInt32?
    var model: String?
    var approvalPolicy: String?
    var sandboxMode: String?
    var cwd: String?
    var permissionMode: String?
    var allowedTools: [String] = []
    var disallowedTools: [String] = []
  }

  struct ForkResponse: Decodable {
    let sourceSessionId: String
    let newSessionId: String
    let session: ServerSessionSummary

    enum CodingKeys: String, CodingKey {
      case sourceSessionId = "source_session_id"
      case newSessionId = "new_session_id"
      case session
    }
  }

  struct ForkToWorktreeRequest: Encodable {
    let branchName: String
    var baseBranch: String?
    var nthUserMessage: UInt32?
  }

  struct ForkToWorktreeResponse: Decodable {
    let sourceSessionId: String
    let newSessionId: String
    let session: ServerSessionSummary
    let worktree: ServerWorktreeSummary

    enum CodingKeys: String, CodingKey {
      case sourceSessionId = "source_session_id"
      case newSessionId = "new_session_id"
      case session
      case worktree
    }
  }

  struct ForkToExistingWorktreeRequest: Encodable {
    let worktreeId: String
    var nthUserMessage: UInt32?
  }

  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func fetchSessionsList() async throws -> [ServerSessionListItem] {
    let response: SessionsListResponse = try await http.get("/api/sessions")
    return response.sessions
  }

  func fetchSessionSnapshot(_ sessionId: String) async throws -> ServerSessionState {
    let response: SessionSnapshotResponse = try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))"
    )
    return response.session
  }

  func createSession(_ request: CreateSessionRequest) async throws -> CreateSessionResponse {
    try await http.post("/api/sessions", body: request)
  }

  func fetchCodexPreferences() async throws -> CodexPreferencesResponse {
    try await http.get("/api/server/codex-preferences")
  }

  func updateCodexPreferences(_ request: UpdateCodexPreferencesRequest) async throws -> CodexPreferencesResponse {
    try await http.request(
      path: "/api/server/codex-preferences",
      method: "PUT",
      body: request
    )
  }

  func inspectCodexConfig(_ request: CodexInspectRequest) async throws -> CodexInspectorResponse {
    try await http.post("/api/codex/config/inspect", body: request)
  }

  func resumeSession(_ sessionId: String) async throws -> ResumeSessionResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/resume",
      body: ServerEmptyBody()
    )
  }

  func takeoverSession(_ sessionId: String, request: TakeoverRequest) async throws -> TakeoverResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/takeover",
      body: request
    )
  }

  func endSession(_ sessionId: String) async throws {
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/end",
      body: ServerEmptyBody()
    )
  }

  func renameSession(_ sessionId: String, name: String?) async throws {
    struct Body: Encodable { let name: String? }
    let _: ServerAcceptedResponse = try await http.request(
      path: "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/name",
      method: "PATCH",
      body: Body(name: name)
    )
  }

  func updateSessionConfig(_ sessionId: String, config: UpdateSessionConfigRequest) async throws {
    let _: ServerAcceptedResponse = try await http.request(
      path: "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/config",
      method: "PATCH",
      body: config
    )
  }

  func updateCodexSessionOverrides(
    _ sessionId: String,
    config: UpdateCodexSessionOverridesRequest
  ) async throws {
    let _: ServerAcceptedResponse = try await http.request(
      path: "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/config",
      method: "PATCH",
      body: config
    )
  }

  func forkSession(_ sourceSessionId: String, request: ForkRequest) async throws -> ForkResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sourceSessionId))/fork",
      body: request
    )
  }

  func forkSessionToWorktree(
    _ sourceSessionId: String,
    request: ForkToWorktreeRequest
  ) async throws -> ForkToWorktreeResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sourceSessionId))/fork-to-worktree",
      body: request
    )
  }

  func forkSessionToExistingWorktree(
    _ sourceSessionId: String,
    request: ForkToExistingWorktreeRequest
  ) async throws -> ForkResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sourceSessionId))/fork-to-existing-worktree",
      body: request
    )
  }

  func getSubagentTools(sessionId: String, subagentId: String) async throws -> [ServerSubagentTool] {
    struct Response: Decodable { let tools: [ServerSubagentTool] }
    let response: Response = try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/subagents/\(requestBuilder.encodePathComponent(subagentId))/tools"
    )
    return response.tools
  }

  func getSubagentMessages(sessionId: String, subagentId: String) async throws -> [ServerConversationRowEntry] {
    struct Response: Decodable { let rows: [ServerConversationRowEntry] }
    let response: Response = try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/subagents/\(requestBuilder.encodePathComponent(subagentId))/messages"
    )
    return response.rows
  }

  func markSessionRead(_ sessionId: String) async throws -> UInt64 {
    struct Response: Decodable {
      let unreadCount: UInt64
      enum CodingKeys: String, CodingKey { case unreadCount = "unread_count" }
    }
    let response: Response = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/mark-read",
      body: ServerEmptyBody()
    )
    return response.unreadCount
  }
}
