import Foundation

extension APIClient {

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
}
