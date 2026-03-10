import Foundation

extension APIClient {

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
}
