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

  func fetchUsageSummary(todayStartUnix: UInt64?) async throws -> ServerUsageSummarySnapshotPayload {
    var query: [URLQueryItem] = []
    if let todayStartUnix {
      query.append(URLQueryItem(name: "today_start_unix", value: String(todayStartUnix)))
    }
    return try await http.get("/api/usage/summary", query: query)
  }

  func listCodexModels(
    cwd: String? = nil,
    modelProvider: String? = nil
  ) async throws -> [ServerCodexModelOption] {
    struct Response: Decodable { let models: [ServerCodexModelOption] }
    var query: [URLQueryItem] = []
    if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      query.append(URLQueryItem(name: "cwd", value: cwd))
    }
    if let modelProvider, !modelProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      query.append(URLQueryItem(name: "model_provider", value: modelProvider))
    }
    let response: Response = try await http.get("/api/models/codex", query: query)
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
