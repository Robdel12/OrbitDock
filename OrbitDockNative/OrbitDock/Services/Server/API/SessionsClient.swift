import Foundation

struct SessionsClient: Sendable {
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
