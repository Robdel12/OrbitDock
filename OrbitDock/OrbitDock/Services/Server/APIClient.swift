//
//  APIClient.swift
//  OrbitDock
//
//  Standalone HTTP transport for the OrbitDock server.
//  No state, no callbacks — pure async/await.
//

import Foundation

// MARK: - Connection Status

enum ConnectionStatus: Equatable, Hashable {
  case disconnected
  case connecting
  case connected
  case failed(String)
}

// MARK: - Errors

enum ServerRequestError: LocalizedError {
  case notConnected
  case connectionLost
  case invalidEndpoint
  case invalidResponse
  case httpStatus(Int, code: String? = nil, message: String? = nil)

  var statusCode: Int? {
    switch self {
    case let .httpStatus(status, _, _): status
    default: nil
    }
  }

  var apiErrorCode: String? {
    switch self {
    case let .httpStatus(_, code, _): code
    default: nil
    }
  }

  var isConnectorUnavailableConflict: Bool {
    statusCode == 409 && apiErrorCode == "session_not_found"
  }

  var errorDescription: String? {
    switch self {
    case .notConnected:
      "Server is not connected."
    case .connectionLost:
      "Server connection was lost before the request completed."
    case .invalidEndpoint:
      "Server endpoint URL is invalid."
    case .invalidResponse:
      "Server returned an invalid response."
    case let .httpStatus(status, code, message):
      if let code, let message {
        "Server request failed with status \(status) (\(code)): \(message)"
      } else if let code {
        "Server request failed with status \(status) (\(code))."
      } else {
        "Server request failed with status \(status)."
      }
    }
  }
}

// MARK: - APIClient

/// Pure HTTP transport for the OrbitDock server REST API.
/// Stateless — callers supply the base URL and auth token on init.
final class APIClient: Sendable {
  let baseURL: URL
  private let authToken: String?

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.keyEncodingStrategy = .convertToSnakeCase
    return e
  }()

  private static let decoder = JSONDecoder()

  init(serverURL: URL, authToken: String?) {
    self.baseURL = Self.httpBaseURL(from: serverURL)
    self.authToken = authToken
    netLog(.info, cat: .api, "Initialized", data: ["baseURL": self.baseURL.absoluteString])
  }

  // MARK: - Sessions (list / fetch)

  func fetchSessionsList() async throws -> [ServerSessionSummary] {
    let resp: SessionsListResponse = try await get("/api/sessions")
    return resp.sessions
  }

  func fetchSessionSnapshot(_ sessionId: String) async throws -> ServerSessionState {
    let resp: SessionSnapshotResponse = try await get(
      "/api/sessions/\(encode(sessionId))")
    return resp.session
  }

  func fetchConversationBootstrap(
    _ sessionId: String, limit: Int = 200
  ) async throws -> ServerConversationBootstrap {
    try await get(
      "/api/sessions/\(encode(sessionId))/conversation",
      query: [URLQueryItem(name: "limit", value: "\(limit)")]
    )
  }

  func fetchConversationHistory(
    _ sessionId: String, beforeSequence: UInt64, limit: Int = 100
  ) async throws -> ServerConversationHistoryPage {
    try await get(
      "/api/sessions/\(encode(sessionId))/messages",
      query: [
        URLQueryItem(name: "limit", value: "\(limit)"),
        URLQueryItem(name: "before_sequence", value: "\(beforeSequence)"),
      ]
    )
  }

  // MARK: - Session lifecycle

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

  // MARK: - Fork

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

  // MARK: - Messaging

  struct SendMessageRequest: Encodable {
    let content: String
    var model: String?
    var effort: String?
    var skills: [ServerSkillInput] = []
    var images: [ServerImageInput] = []
    var mentions: [ServerMentionInput] = []
  }

  func sendMessage(_ sessionId: String, request: SendMessageRequest) async throws {
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/messages", method: "POST",
      body: request)
  }

  struct SteerTurnRequest: Encodable {
    let content: String
    var images: [ServerImageInput] = []
    var mentions: [ServerMentionInput] = []
  }

  func steerTurn(_ sessionId: String, request: SteerTurnRequest) async throws {
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/steer", method: "POST",
      body: request)
  }

  // MARK: - Session actions

  func interruptSession(_ sessionId: String) async throws {
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/interrupt", body: EmptyBody())
  }

  func compactContext(_ sessionId: String) async throws {
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/compact", body: EmptyBody())
  }

  func undoLastTurn(_ sessionId: String) async throws {
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/undo", body: EmptyBody())
  }

  func rollbackTurns(_ sessionId: String, numTurns: UInt32) async throws {
    struct Body: Encodable { let numTurns: UInt32 }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/rollback",
      body: Body(numTurns: numTurns))
  }

  func stopTask(_ sessionId: String, taskId: String) async throws {
    struct Body: Encodable { let taskId: String }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/stop-task",
      body: Body(taskId: taskId))
  }

  func rewindFiles(_ sessionId: String, userMessageId: String) async throws {
    struct Body: Encodable { let userMessageId: String }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/rewind-files",
      body: Body(userMessageId: userMessageId))
  }

  // MARK: - Approvals

  struct ApproveToolRequest: Encodable {
    let requestId: String
    let decision: String
    var message: String?
    var interrupt: Bool?
    // updatedInput is passed as raw JSON via serde_json::Value on server.
    // Callers should encode it separately if needed.
  }

  struct ApprovalDecisionResponse: Decodable {
    let sessionId: String
    let requestId: String
    let outcome: String
    let activeRequestId: String?
    let approvalVersion: UInt64

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case requestId = "request_id"
      case outcome
      case activeRequestId = "active_request_id"
      case approvalVersion = "approval_version"
    }
  }

  func approveTool(
    _ sessionId: String, request: ApproveToolRequest
  ) async throws -> ApprovalDecisionResponse {
    try await post("/api/sessions/\(encode(sessionId))/approve", body: request)
  }

  struct AnswerQuestionRequest: Encodable {
    let requestId: String
    let answer: String
    var questionId: String?
    var answers: [String: [String]] = [:]
  }

  func answerQuestion(
    _ sessionId: String, request: AnswerQuestionRequest
  ) async throws -> ApprovalDecisionResponse {
    try await post("/api/sessions/\(encode(sessionId))/answer", body: request)
  }

  func listApprovals(
    sessionId: String? = nil, limit: Int = 50
  ) async throws -> ApprovalsResponse {
    var query = [URLQueryItem(name: "limit", value: "\(limit)")]
    if let sid = sessionId {
      query.append(URLQueryItem(name: "session_id", value: sid))
    }
    return try await get("/api/approvals", query: query)
  }

  struct ApprovalsResponse: Decodable {
    let sessionId: String?
    let approvals: [ServerApprovalHistoryItem]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case approvals
    }
  }

  func deleteApproval(_ approvalId: Int64) async throws {
    struct Resp: Decodable { let deleted: Bool }
    let _: Resp = try await request(
      path: "/api/approvals/\(approvalId)", method: "DELETE")
  }

  // MARK: - Image attachments

  func uploadImageAttachment(
    sessionId: String, data: Data, mimeType: String,
    displayName: String, pixelWidth: Int, pixelHeight: Int
  ) async throws -> ServerImageInput {
    let resp: UploadedImageAttachmentResponse = try await requestRaw(
      path: "/api/sessions/\(encode(sessionId))/attachments/images",
      method: "POST",
      bodyData: data,
      contentType: mimeType,
      query: [
        URLQueryItem(name: "display_name", value: displayName),
        URLQueryItem(name: "pixel_width", value: "\(pixelWidth)"),
        URLQueryItem(name: "pixel_height", value: "\(pixelHeight)"),
      ]
    )
    return resp.image
  }

  func downloadImageAttachment(
    sessionId: String, attachmentId: String
  ) async throws -> Data {
    try await fetchData(
      "/api/sessions/\(encode(sessionId))/attachments/images/\(encode(attachmentId))")
  }

  // MARK: - Usage

  struct CodexUsageResponse: Decodable {
    let usage: ServerCodexUsageSnapshot?
    let errorInfo: ServerUsageErrorInfo?

    enum CodingKeys: String, CodingKey {
      case usage
      case errorInfo = "error_info"
    }
  }

  func fetchCodexUsage() async throws -> CodexUsageResponse {
    try await get("/api/usage/codex")
  }

  struct ClaudeUsageResponse: Decodable {
    let usage: ServerClaudeUsageSnapshot?
    let errorInfo: ServerUsageErrorInfo?

    enum CodingKeys: String, CodingKey {
      case usage
      case errorInfo = "error_info"
    }
  }

  func fetchClaudeUsage() async throws -> ClaudeUsageResponse {
    try await get("/api/usage/claude")
  }

  // MARK: - Models

  func listCodexModels() async throws -> [ServerCodexModelOption] {
    struct Resp: Decodable { let models: [ServerCodexModelOption] }
    let resp: Resp = try await get("/api/models/codex")
    return resp.models
  }

  func listClaudeModels() async throws -> [ServerClaudeModelOption] {
    struct Resp: Decodable { let models: [ServerClaudeModelOption] }
    let resp: Resp = try await get("/api/models/claude")
    return resp.models
  }

  // MARK: - Codex account

  func readCodexAccount(refreshToken: String? = nil) async throws -> ServerCodexAccountStatus {
    var query: [URLQueryItem] = []
    if let token = refreshToken {
      query.append(URLQueryItem(name: "refresh_token", value: token))
    }
    struct Resp: Decodable { let status: ServerCodexAccountStatus }
    let resp: Resp = try await get("/api/codex/account", query: query)
    return resp.status
  }

  struct CodexLoginStartResponse: Decodable {
    let loginId: String
    let authUrl: String

    enum CodingKeys: String, CodingKey {
      case loginId = "login_id"
      case authUrl = "auth_url"
    }
  }

  func startCodexLogin() async throws -> CodexLoginStartResponse {
    try await post("/api/codex/login/start", body: EmptyBody())
  }

  func cancelCodexLogin(loginId: String) async throws {
    struct Body: Encodable { let loginId: String }
    struct Resp: Decodable { let status: String }
    let _: Resp = try await post(
      "/api/codex/login/cancel", body: Body(loginId: loginId))
  }

  func logoutCodexAccount() async throws -> ServerCodexAccountStatus {
    struct Resp: Decodable { let status: ServerCodexAccountStatus }
    let resp: Resp = try await post("/api/codex/logout", body: EmptyBody())
    return resp.status
  }

  // MARK: - OpenAI key

  func setOpenAiKey(_ key: String) async throws {
    struct Body: Encodable { let key: String }
    struct Resp: Decodable { let configured: Bool }
    let _: Resp = try await post("/api/server/openai-key", body: Body(key: key))
  }

  func checkOpenAiKeyStatus() async throws -> Bool {
    struct Resp: Decodable { let configured: Bool }
    let resp: Resp = try await get("/api/server/openai-key")
    return resp.configured
  }

  // MARK: - Server role

  func setServerRole(isPrimary: Bool) async throws -> Bool {
    struct Body: Encodable { let isPrimary: Bool }
    struct Resp: Decodable {
      let isPrimary: Bool
      enum CodingKeys: String, CodingKey { case isPrimary = "is_primary" }
    }
    let resp: Resp = try await request(
      path: "/api/server/role", method: "PUT",
      body: Body(isPrimary: isPrimary))
    return resp.isPrimary
  }

  // MARK: - Filesystem

  func listRecentProjects() async throws -> [ServerRecentProject] {
    struct Resp: Decodable { let projects: [ServerRecentProject] }
    let resp: Resp = try await get("/api/fs/recent-projects")
    return resp.projects
  }

  func browseDirectory(path: String) async throws -> (String, [ServerDirectoryEntry]) {
    struct Resp: Decodable { let path: String; let entries: [ServerDirectoryEntry] }
    let resp: Resp = try await get(
      "/api/fs/browse",
      query: [URLQueryItem(name: "path", value: path)])
    return (resp.path, resp.entries)
  }

  // MARK: - Skills

  struct SkillsResponse: Decodable {
    let sessionId: String
    let skills: [ServerSkillsListEntry]
    let errors: [ServerSkillErrorInfo]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case skills
      case errors
    }
  }

  func listSkills(
    sessionId: String, cwds: [String] = [], forceReload: Bool = false
  ) async throws -> SkillsResponse {
    var query: [URLQueryItem] = []
    for cwd in cwds { query.append(URLQueryItem(name: "cwd", value: cwd)) }
    if forceReload { query.append(URLQueryItem(name: "force_reload", value: "true")) }
    return try await get("/api/sessions/\(encode(sessionId))/skills", query: query)
  }

  struct RemoteSkillsResponse: Decodable {
    let sessionId: String
    let skills: [ServerRemoteSkillSummary]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case skills
    }
  }

  func listRemoteSkills(sessionId: String) async throws -> RemoteSkillsResponse {
    try await get("/api/sessions/\(encode(sessionId))/skills/remote")
  }

  func downloadRemoteSkill(sessionId: String, hazelnutId: String) async throws {
    struct Body: Encodable { let hazelnutId: String }
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/skills/download", method: "POST",
      body: Body(hazelnutId: hazelnutId))
  }

  // MARK: - MCP

  struct McpToolsResponse: Decodable {
    let sessionId: String
    let tools: [String: ServerMcpTool]
    let resources: [String: [ServerMcpResource]]
    let resourceTemplates: [String: [ServerMcpResourceTemplate]]
    let authStatuses: [String: ServerMcpAuthStatus]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case tools
      case resources
      case resourceTemplates = "resource_templates"
      case authStatuses = "auth_statuses"
    }
  }

  func listMcpTools(sessionId: String) async throws -> McpToolsResponse {
    try await get("/api/sessions/\(encode(sessionId))/mcp/tools")
  }

  func refreshMcpServers(sessionId: String) async throws {
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/mcp/refresh", method: "POST",
      body: EmptyBody())
  }

  func toggleMcpServer(sessionId: String, serverName: String, enabled: Bool) async throws {
    struct Body: Encodable { let serverName: String; let enabled: Bool }
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/mcp/toggle", method: "POST",
      body: Body(serverName: serverName, enabled: enabled))
  }

  func mcpAuthenticate(sessionId: String, serverName: String) async throws {
    struct Body: Encodable { let serverName: String }
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/mcp/authenticate", method: "POST",
      body: Body(serverName: serverName))
  }

  func mcpClearAuth(sessionId: String, serverName: String) async throws {
    struct Body: Encodable { let serverName: String }
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/mcp/clear-auth", method: "POST",
      body: Body(serverName: serverName))
  }

  func mcpSetServers(sessionId: String, config: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: config)
    try await fireAndForgetRaw(
      "/api/sessions/\(encode(sessionId))/mcp/servers", method: "POST",
      bodyData: data)
  }

  // MARK: - Permissions

  func fetchPermissionRules(
    _ sessionId: String
  ) async throws -> ServerPermissionRulesResponse {
    try await get("/api/sessions/\(encode(sessionId))/permissions")
  }

  func addPermissionRule(
    sessionId: String, pattern: String, behavior: String, scope: String
  ) async throws {
    let _: ModifyPermissionRuleHTTPResponse = try await post(
      "/api/sessions/\(encode(sessionId))/permissions/rules",
      body: PermissionRuleMutationBody(pattern: pattern, behavior: behavior, scope: scope))
  }

  func removePermissionRule(
    sessionId: String, pattern: String, behavior: String, scope: String
  ) async throws {
    let _: ModifyPermissionRuleHTTPResponse = try await request(
      path: "/api/sessions/\(encode(sessionId))/permissions/rules",
      method: "DELETE",
      body: PermissionRuleMutationBody(pattern: pattern, behavior: behavior, scope: scope))
  }

  // MARK: - Review comments

  struct ReviewCommentsResponse: Decodable {
    let sessionId: String
    let comments: [ServerReviewComment]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case comments
    }
  }

  func listReviewComments(
    sessionId: String, turnId: String? = nil
  ) async throws -> ReviewCommentsResponse {
    var query: [URLQueryItem] = []
    if let tid = turnId { query.append(URLQueryItem(name: "turn_id", value: tid)) }
    return try await get(
      "/api/sessions/\(encode(sessionId))/review-comments", query: query)
  }

  struct CreateReviewCommentRequest: Encodable {
    let turnId: String?
    let filePath: String
    let lineStart: UInt32
    let lineEnd: UInt32?
    let body: String
    let tag: ServerReviewCommentTag?
  }

  func createReviewComment(
    sessionId: String, request: CreateReviewCommentRequest
  ) async throws -> String {
    struct Resp: Decodable {
      let commentId: String
      enum CodingKeys: String, CodingKey { case commentId = "comment_id" }
    }
    let resp: Resp = try await post(
      "/api/sessions/\(encode(sessionId))/review-comments", body: request)
    return resp.commentId
  }

  struct UpdateReviewCommentRequest: Encodable {
    var body: String?
    var tag: ServerReviewCommentTag?
    var status: ServerReviewCommentStatus?
  }

  func updateReviewComment(
    commentId: String, body: UpdateReviewCommentRequest
  ) async throws {
    struct Resp: Decodable { let ok: Bool }
    let _: Resp = try await request(
      path: "/api/review-comments/\(encode(commentId))", method: "PATCH",
      body: body)
  }

  func deleteReviewComment(commentId: String) async throws {
    struct Resp: Decodable { let ok: Bool }
    let _: Resp = try await request(
      path: "/api/review-comments/\(encode(commentId))", method: "DELETE")
  }

  // MARK: - Subagent tools

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

  // MARK: - Session mark-read

  func markSessionRead(_ sessionId: String) async throws -> UInt64 {
    struct Resp: Decodable {
      let unreadCount: UInt64
      enum CodingKeys: String, CodingKey { case unreadCount = "unread_count" }
    }
    let resp: Resp = try await post(
      "/api/sessions/\(encode(sessionId))/mark-read", body: EmptyBody())
    return resp.unreadCount
  }

  // MARK: - Worktrees

  func listWorktrees(repoRoot: String) async throws -> [ServerWorktreeSummary] {
    struct Resp: Decodable {
      let worktrees: [ServerWorktreeSummary]
    }
    let resp: Resp = try await get(
      "/api/worktrees",
      query: [URLQueryItem(name: "repo_root", value: repoRoot)])
    return resp.worktrees
  }

  func createWorktree(
    repoPath: String, branchName: String, baseBranch: String?
  ) async throws -> ServerWorktreeSummary {
    struct Body: Encodable {
      let repoPath: String; let branchName: String; let baseBranch: String?
    }
    struct Resp: Decodable { let worktree: ServerWorktreeSummary }
    let resp: Resp = try await post(
      "/api/worktrees",
      body: Body(repoPath: repoPath, branchName: branchName, baseBranch: baseBranch))
    return resp.worktree
  }

  func removeWorktree(
    worktreeId: String, force: Bool = false, deleteBranch: Bool = false,
    deleteRemoteBranch: Bool = false, archiveOnly: Bool = false
  ) async throws {
    struct Resp: Decodable { let ok: Bool }
    let _: Resp = try await request(
      path: "/api/worktrees/\(encode(worktreeId))", method: "DELETE",
      query: [
        URLQueryItem(name: "force", value: force ? "true" : "false"),
        URLQueryItem(name: "delete_branch", value: deleteBranch ? "true" : "false"),
        URLQueryItem(
          name: "delete_remote_branch", value: deleteRemoteBranch ? "true" : "false"),
        URLQueryItem(name: "archive_only", value: archiveOnly ? "true" : "false"),
      ])
  }

  func discoverWorktrees(repoPath: String) async throws -> [ServerWorktreeSummary] {
    struct Body: Encodable { let repoPath: String }
    struct Resp: Decodable { let worktrees: [ServerWorktreeSummary] }
    let resp: Resp = try await post(
      "/api/worktrees/discover", body: Body(repoPath: repoPath))
    return resp.worktrees
  }

  // MARK: - Git

  func gitInit(path: String) async throws -> Bool {
    struct Body: Encodable { let path: String }
    struct Resp: Decodable { let ok: Bool }
    let resp: Resp = try await post("/api/git/init", body: Body(path: path))
    return resp.ok
  }

  // MARK: - Flags

  func applyFlagSettings(sessionId: String, settings: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: settings)
    try await fireAndForgetRaw(
      "/api/sessions/\(encode(sessionId))/flags", method: "POST",
      bodyData: data)
  }

  // MARK: - Shell

  func executeShell(
    sessionId: String, command: String, timeoutSecs: UInt64 = 120
  ) async throws {
    struct Body: Encodable { let command: String; let timeoutSecs: UInt64 }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/shell/exec",
      body: Body(command: command, timeoutSecs: timeoutSecs))
  }

  func cancelShell(sessionId: String, requestId: String) async throws {
    struct Body: Encodable { let requestId: String }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/shell/cancel",
      body: Body(requestId: requestId))
  }

  // MARK: - Client primary claim

  func setClientPrimaryClaim(
    clientId: String, deviceName: String, isPrimary: Bool
  ) async throws {
    struct Body: Encodable {
      let clientId: String; let deviceName: String; let isPrimary: Bool
    }
    let _: AcceptedResponse = try await post(
      "/api/client/primary-claim",
      body: Body(clientId: clientId, deviceName: deviceName, isPrimary: isPrimary))
  }
}

// MARK: - HTTP Primitives

extension APIClient {

  /// GET that decodes JSON response.
  private func get<R: Decodable>(
    _ path: String, query: [URLQueryItem] = []
  ) async throws -> R {
    try await request(path: path, method: "GET", query: query)
  }

  /// POST with Encodable body that decodes JSON response.
  private func post<B: Encodable, R: Decodable>(
    _ path: String, body: B, query: [URLQueryItem] = []
  ) async throws -> R {
    try await request(path: path, method: "POST", body: body, query: query)
  }

  /// Request with optional body, decoding JSON response.
  private func request<R: Decodable>(
    path: String, method: String, query: [URLQueryItem] = []
  ) async throws -> R {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 15
    applyAuth(to: &req)

    let (data, response) = try await URLSession.shared.data(for: req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
    do {
      return try Self.decoder.decode(R.self, from: data)
    } catch {
      netLog(.error, cat: .api, "Decode failed \(method) \(path)", data: ["error": error.localizedDescription])
      throw error
    }
  }

  /// Request with Encodable body, decoding JSON response.
  private func request<B: Encodable, R: Decodable>(
    path: String, method: String, body: B, query: [URLQueryItem] = []
  ) async throws -> R {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &req)
    req.httpBody = try Self.encoder.encode(body)

    let (data, response) = try await URLSession.shared.data(for: req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
    do {
      return try Self.decoder.decode(R.self, from: data)
    } catch {
      netLog(.error, cat: .api, "Decode failed \(method) \(path)", data: ["error": error.localizedDescription])
      throw error
    }
  }

  /// Fire-and-forget: sends body, validates 2xx, discards response body.
  private func fireAndForget<B: Encodable>(
    _ path: String, method: String, body: B, query: [URLQueryItem] = []
  ) async throws {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &req)
    req.httpBody = try Self.encoder.encode(body)

    let (data, response) = try await URLSession.shared.data(for: req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
  }

  /// Fire-and-forget with raw Data body.
  private func fireAndForgetRaw(
    _ path: String, method: String, bodyData: Data, query: [URLQueryItem] = []
  ) async throws {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuth(to: &req)
    req.httpBody = bodyData

    let (data, response) = try await URLSession.shared.data(for: req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
  }

  /// Send raw Data body with custom content type, decode JSON response.
  private func requestRaw<R: Decodable>(
    path: String, method: String, bodyData: Data, contentType: String,
    query: [URLQueryItem] = []
  ) async throws -> R {
    netLog(.debug, cat: .api, "→ \(method) \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 30
    req.setValue(contentType, forHTTPHeaderField: "Content-Type")
    applyAuth(to: &req)
    req.httpBody = bodyData

    let (data, response) = try await URLSession.shared.data(for: req)
    try validateHTTPResponse(response, data: data, method: method, path: path)
    do {
      return try Self.decoder.decode(R.self, from: data)
    } catch {
      netLog(.error, cat: .api, "Decode failed \(method) \(path)", data: ["error": error.localizedDescription])
      throw error
    }
  }

  /// Fetch raw Data (GET).
  private func fetchData(
    _ path: String, query: [URLQueryItem] = []
  ) async throws -> Data {
    netLog(.debug, cat: .api, "→ GET \(path)")
    guard let url = buildURL(path: path, query: query) else {
      throw ServerRequestError.invalidEndpoint
    }

    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 30
    applyAuth(to: &req)

    let (data, response) = try await URLSession.shared.data(for: req)
    try validateHTTPResponse(response, data: data, method: "GET", path: path)
    return data
  }

  // MARK: - Helpers

  private func applyAuth(to request: inout URLRequest) {
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
  }

  private func validateHTTPResponse(
    _ response: URLResponse, data: Data, method: String = "?", path: String = "?"
  ) throws {
    guard let http = response as? HTTPURLResponse else {
      netLog(.error, cat: .api, "Invalid response \(method) \(path)")
      throw ServerRequestError.invalidResponse
    }
    guard (200 ..< 300).contains(http.statusCode) else {
      let apiError = try? Self.decoder.decode(APIErrorResponse.self, from: data)
      netLog(.error, cat: .api, "HTTP \(http.statusCode) \(method) \(path)", data: ["code": apiError?.code ?? "-", "error": apiError?.error ?? "-"])
      throw ServerRequestError.httpStatus(
        http.statusCode,
        code: apiError?.code,
        message: apiError?.error
      )
    }
  }

  private func buildURL(path: String, query: [URLQueryItem]) -> URL? {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
    if components.path.isEmpty || components.path == "/" {
      components.path = normalizedPath
    } else {
      var base = components.path
      if base.hasSuffix("/") { base.removeLast() }
      components.path = "\(base)\(normalizedPath)"
    }
    components.queryItems = query.isEmpty ? nil : query
    return components.url
  }

  private func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  /// Convert ws/wss server URL to http/https base URL (stripping /ws path suffix).
  static func httpBaseURL(from serverURL: URL) -> URL {
    guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
      return serverURL
    }
    if components.scheme == "wss" {
      components.scheme = "https"
    } else if components.scheme == "ws" {
      components.scheme = "http"
    }
    if components.path.hasSuffix("/ws") {
      components.path = String(components.path.dropLast(3))
    }
    return components.url ?? serverURL
  }
}

// MARK: - Shared Response Types

extension APIClient {

  struct SessionsListResponse: Decodable {
    let sessions: [ServerSessionSummary]
  }

  struct SessionSnapshotResponse: Decodable {
    let session: ServerSessionState
  }

  struct AcceptedResponse: Decodable {
    let accepted: Bool
  }

  struct APIErrorResponse: Decodable {
    let code: String
    let error: String
  }

  struct UploadedImageAttachmentResponse: Decodable {
    let image: ServerImageInput
  }

  struct EmptyBody: Encodable {}
}

