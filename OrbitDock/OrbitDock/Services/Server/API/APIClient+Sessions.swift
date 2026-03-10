import Foundation

extension APIClient {

  func fetchSessionsList() async throws -> [ServerSessionSummary] {
    let resp: SessionsListResponse = try await get("/api/sessions")
    return resp.sessions
  }

  func fetchSessionSnapshot(_ sessionId: String) async throws -> ServerSessionState {
    let resp: SessionSnapshotResponse = try await get(
      "/api/sessions/\(encode(sessionId))")
    return resp.session
  }

  struct CreateSessionRequest: Encodable {
    let provider: String
    let cwd: String
    var model: String?
    var approvalPolicy: String?
    var sandboxMode: String?
    var permissionMode: String?
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

  func createSession(_ request: CreateSessionRequest) async throws -> CreateSessionResponse {
    try await post("/api/sessions", body: request)
  }

  struct ResumeSessionResponse: Decodable {
    let sessionId: String
    let session: ServerSessionSummary

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case session
    }
  }

  func resumeSession(_ sessionId: String) async throws -> ResumeSessionResponse {
    try await post("/api/sessions/\(encode(sessionId))/resume", body: EmptyBody())
  }

  struct TakeoverRequest: Encodable {
    var model: String?
    var approvalPolicy: String?
    var sandboxMode: String?
    var permissionMode: String?
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

  func takeoverSession(
    _ sessionId: String, request: TakeoverRequest
  ) async throws -> TakeoverResponse {
    try await post("/api/sessions/\(encode(sessionId))/takeover", body: request)
  }

  func endSession(_ sessionId: String) async throws {
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/end", body: EmptyBody())
  }

  func renameSession(_ sessionId: String, name: String?) async throws {
    struct Body: Encodable { let name: String? }
    let _: AcceptedResponse = try await request(
      path: "/api/sessions/\(encode(sessionId))/name", method: "PATCH",
      body: Body(name: name))
  }

  struct UpdateSessionConfigRequest: Encodable {
    var approvalPolicy: String?
    var sandboxMode: String?
    var permissionMode: String?
  }

  func updateSessionConfig(
    _ sessionId: String, config: UpdateSessionConfigRequest
  ) async throws {
    let _: AcceptedResponse = try await request(
      path: "/api/sessions/\(encode(sessionId))/config", method: "PATCH",
      body: config)
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

  func forkSession(
    _ sourceSessionId: String, request: ForkRequest
  ) async throws -> ForkResponse {
    try await post("/api/sessions/\(encode(sourceSessionId))/fork", body: request)
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

  func forkSessionToWorktree(
    _ sourceSessionId: String, request: ForkToWorktreeRequest
  ) async throws -> ForkToWorktreeResponse {
    try await post(
      "/api/sessions/\(encode(sourceSessionId))/fork-to-worktree",
      body: request)
  }

  struct ForkToExistingWorktreeRequest: Encodable {
    let worktreeId: String
    var nthUserMessage: UInt32?
  }

  func forkSessionToExistingWorktree(
    _ sourceSessionId: String, request: ForkToExistingWorktreeRequest
  ) async throws -> ForkResponse {
    try await post(
      "/api/sessions/\(encode(sourceSessionId))/fork-to-existing-worktree",
      body: request)
  }

  func getSubagentTools(
    sessionId: String, subagentId: String
  ) async throws -> [ServerSubagentTool] {
    struct Resp: Decodable {
      let tools: [ServerSubagentTool]
    }
    let resp: Resp = try await get(
      "/api/sessions/\(encode(sessionId))/subagents/\(encode(subagentId))/tools")
    return resp.tools
  }

  func markSessionRead(_ sessionId: String) async throws -> UInt64 {
    struct Resp: Decodable {
      let unreadCount: UInt64
      enum CodingKeys: String, CodingKey { case unreadCount = "unread_count" }
    }
    let resp: Resp = try await post(
      "/api/sessions/\(encode(sessionId))/mark-read", body: EmptyBody())
    return resp.unreadCount
  }
}
