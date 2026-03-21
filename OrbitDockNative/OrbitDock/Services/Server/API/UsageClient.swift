import Foundation

struct UsageClient: Sendable {
  struct CodexUsageResponse: Decodable {
    let usage: ServerCodexUsageSnapshot?
    let errorInfo: ServerUsageErrorInfo?

    enum CodingKeys: String, CodingKey {
      case usage
      case errorInfo = "error_info"
    }
  }

  struct ClaudeUsageResponse: Decodable {
    let usage: ServerClaudeUsageSnapshot?
    let errorInfo: ServerUsageErrorInfo?

    enum CodingKeys: String, CodingKey {
      case usage
      case errorInfo = "error_info"
    }
  }

  struct CodexLoginStartResponse: Decodable {
    let loginId: String
    let authUrl: String

    enum CodingKeys: String, CodingKey {
      case loginId = "login_id"
      case authUrl = "auth_url"
    }
  }

  private let http: ServerHTTPClient

  init(http: ServerHTTPClient) {
    self.http = http
  }

  func fetchCodexUsage() async throws -> CodexUsageResponse {
    try await http.get("/api/usage/codex")
  }

  func fetchClaudeUsage() async throws -> ClaudeUsageResponse {
    try await http.get("/api/usage/claude")
  }

  func listCodexModels() async throws -> [ServerCodexModelOption] {
    struct Response: Decodable { let models: [ServerCodexModelOption] }
    let response: Response = try await http.get("/api/models/codex")
    return response.models
  }

  func readCodexAccount(refreshToken: String? = nil) async throws -> ServerCodexAccountStatus {
    var query: [URLQueryItem] = []
    if let token = refreshToken {
      query.append(URLQueryItem(name: "refresh_token", value: token))
    }
    struct Response: Decodable { let status: ServerCodexAccountStatus }
    let response: Response = try await http.get("/api/codex/account", query: query)
    return response.status
  }

  func startCodexLogin() async throws -> CodexLoginStartResponse {
    try await http.post("/api/codex/login/start", body: ServerEmptyBody())
  }

  func cancelCodexLogin(loginId: String) async throws {
    struct Body: Encodable { let loginId: String }
    struct Response: Decodable { let status: String }
    let _: Response = try await http.post("/api/codex/login/cancel", body: Body(loginId: loginId))
  }

  func logoutCodexAccount() async throws -> ServerCodexAccountStatus {
    struct Response: Decodable { let status: ServerCodexAccountStatus }
    let response: Response = try await http.post("/api/codex/logout", body: ServerEmptyBody())
    return response.status
  }
}
