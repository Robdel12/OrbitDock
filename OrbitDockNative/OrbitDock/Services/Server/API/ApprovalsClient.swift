import Foundation

struct ApprovalsClient: Sendable {
  enum ToolApprovalDecision: String, Encodable, Sendable {
    case approved
    case approvedForSession = "approved_for_session"
    case approvedAlways = "approved_always"
    case denied
    case abort
  }

  struct ApproveToolRequest: Encodable {
    let requestId: String
    let decision: ToolApprovalDecision
    var message: String?
    var interrupt: Bool?
    var updatedInput: AnyCodable?

    enum CodingKeys: String, CodingKey {
      case decision
      case message
      case interrupt
      case updatedInput = "updated_input"
    }
  }

  struct ApprovalDecisionResponse: Decodable {
    let sessionId: String
    let requestId: String
    let outcome: String
    let activeRequestId: String?
    let approvalVersion: UInt64
    let sessionDetailSnapshot: ServerSessionDetailSnapshotPayload?

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case requestId = "request_id"
      case outcome
      case activeRequestId = "active_request_id"
      case approvalVersion = "approval_version"
      case sessionDetailSnapshot = "session_detail_snapshot"
    }
  }

  struct ReviewCommentMutationResponse: Decodable {
    let sessionId: String
    let reviewRevision: UInt64
    let commentId: String
    let comment: ServerReviewComment?
    let deleted: Bool
    let ok: Bool

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case reviewRevision = "review_revision"
      case commentId = "comment_id"
      case comment
      case deleted
      case ok
    }
  }

  struct AnswerQuestionRequest: Encodable {
    let requestId: String
    let answer: String
    var questionId: String?
    var answers: [String: [String]] = [:]

    enum CodingKeys: String, CodingKey {
      case answer
      case questionId = "question_id"
      case answers
    }
  }

  struct RespondToPermissionRequestRequest: Encodable {
    let requestId: String
    var permissions: [ServerPermissionDescriptor]?
    var scope: ServerPermissionGrantScope?

    enum CodingKeys: String, CodingKey {
      case permissions
      case scope
    }
  }

  struct ApprovalsResponse: Decodable {
    let sessionId: String?
    let approvals: [ServerApprovalHistoryItem]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case approvals
    }
  }

  struct ReviewCommentsResponse: Decodable {
    let sessionId: String
    let comments: [ServerReviewComment]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case comments
    }
  }

  struct CreateReviewCommentRequest: Encodable {
    let turnId: String?
    let filePath: String
    let lineStart: UInt32
    let lineEnd: UInt32?
    let body: String
    let tag: ServerReviewCommentTag?
  }

  struct UpdateReviewCommentRequest: Encodable {
    var body: String?
    var tag: ServerReviewCommentTag?
    var status: ServerReviewCommentStatus?
  }

  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  private func sessionPermissionRulesPath(_ sessionId: String) -> String {
    "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/permissions/rules"
  }

  func approveTool(_ sessionId: String, request: ApproveToolRequest) async throws -> ApprovalDecisionResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/approvals/requests/\(requestBuilder.encodePathComponent(request.requestId))/decision",
      body: request
    )
  }

  func answerQuestion(
    _ sessionId: String,
    request: AnswerQuestionRequest
  ) async throws -> ApprovalDecisionResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/questions/requests/\(requestBuilder.encodePathComponent(request.requestId))/answer",
      body: request
    )
  }

  func respondToPermissionRequest(
    _ sessionId: String,
    request: RespondToPermissionRequestRequest
  ) async throws -> ApprovalDecisionResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/permissions/requests/\(requestBuilder.encodePathComponent(request.requestId))/response",
      body: request
    )
  }

  func listApprovals(sessionId: String? = nil, limit: Int = 50) async throws -> ApprovalsResponse {
    var query = [URLQueryItem(name: "limit", value: "\(limit)")]
    if let sessionId {
      query.append(URLQueryItem(name: "session_id", value: sessionId))
    }
    return try await http.get("/api/approvals", query: query)
  }

  func deleteApproval(_ approvalId: Int64) async throws {
    struct Response: Decodable { let deleted: Bool }
    let _: Response = try await http.request(
      path: "/api/approvals/\(approvalId)",
      method: "DELETE"
    )
  }

  func fetchPermissionRules(_ sessionId: String) async throws -> ServerPermissionRulesResponse {
    try await http.get(sessionPermissionRulesPath(sessionId))
  }

  func addPermissionRule(
    sessionId: String,
    pattern: String,
    behavior: String,
    scope: String
  ) async throws -> ModifyPermissionRuleHTTPResponse {
    try await http.post(
      sessionPermissionRulesPath(sessionId),
      body: PermissionRuleMutationBody(pattern: pattern, behavior: behavior, scope: scope)
    )
  }

  func removePermissionRule(
    sessionId: String,
    pattern: String,
    behavior: String,
    scope: String
  ) async throws -> ModifyPermissionRuleHTTPResponse {
    try await http.request(
      path: sessionPermissionRulesPath(sessionId),
      method: "DELETE",
      body: PermissionRuleMutationBody(pattern: pattern, behavior: behavior, scope: scope)
    )
  }

  func listReviewComments(sessionId: String, turnId: String? = nil) async throws -> ReviewCommentsResponse {
    var query: [URLQueryItem] = []
    if let turnId {
      query.append(URLQueryItem(name: "turn_id", value: turnId))
    }
    return try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/review/comments",
      query: query
    )
  }

  func createReviewComment(
    sessionId: String,
    request: CreateReviewCommentRequest
  ) async throws -> ReviewCommentMutationResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/review/comments",
      body: request
    )
  }

  func updateReviewComment(
    commentId: String,
    body: UpdateReviewCommentRequest
  ) async throws -> ReviewCommentMutationResponse {
    try await http.request(
      path: "/api/review/comments/\(requestBuilder.encodePathComponent(commentId))",
      method: "PATCH",
      body: body
    )
  }

  func deleteReviewComment(commentId: String) async throws -> ReviewCommentMutationResponse {
    try await http.request(
      path: "/api/review/comments/\(requestBuilder.encodePathComponent(commentId))",
      method: "DELETE"
    )
  }
}
