import Foundation

struct ApprovalsClient: Sendable {
  struct ApproveToolRequest: Encodable {
    let requestId: String
    let decision: String
    var message: String?
    var interrupt: Bool?
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

  struct AnswerQuestionRequest: Encodable {
    let requestId: String
    let answer: String
    var questionId: String?
    var answers: [String: [String]] = [:]
  }

  struct RespondToPermissionRequestRequest: Encodable {
    let requestId: String
    var permissions: AnyCodable?
    var scope: ServerPermissionGrantScope?
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

  func approveTool(_ sessionId: String, request: ApproveToolRequest) async throws -> ApprovalDecisionResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/approve",
      body: request
    )
  }

  func answerQuestion(
    _ sessionId: String,
    request: AnswerQuestionRequest
  ) async throws -> ApprovalDecisionResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/answer",
      body: request
    )
  }

  func respondToPermissionRequest(
    _ sessionId: String,
    request: RespondToPermissionRequestRequest
  ) async throws -> ApprovalDecisionResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/permissions/respond",
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
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/permissions"
    )
  }

  func addPermissionRule(
    sessionId: String,
    pattern: String,
    behavior: String,
    scope: String
  ) async throws {
    let _: ModifyPermissionRuleHTTPResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/permissions/rules",
      body: PermissionRuleMutationBody(pattern: pattern, behavior: behavior, scope: scope)
    )
  }

  func removePermissionRule(
    sessionId: String,
    pattern: String,
    behavior: String,
    scope: String
  ) async throws {
    let _: ModifyPermissionRuleHTTPResponse = try await http.request(
      path: "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/permissions/rules",
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
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/review-comments",
      query: query
    )
  }

  func createReviewComment(sessionId: String, request: CreateReviewCommentRequest) async throws -> String {
    struct Response: Decodable {
      let commentId: String
      enum CodingKeys: String, CodingKey { case commentId = "comment_id" }
    }
    let response: Response = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/review-comments",
      body: request
    )
    return response.commentId
  }

  func updateReviewComment(commentId: String, body: UpdateReviewCommentRequest) async throws {
    struct Response: Decodable { let ok: Bool }
    let _: Response = try await http.request(
      path: "/api/review-comments/\(requestBuilder.encodePathComponent(commentId))",
      method: "PATCH",
      body: body
    )
  }

  func deleteReviewComment(commentId: String) async throws {
    struct Response: Decodable { let ok: Bool }
    let _: Response = try await http.request(
      path: "/api/review-comments/\(requestBuilder.encodePathComponent(commentId))",
      method: "DELETE"
    )
  }
}
