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
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
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

  func fetchUsageOverview(
    todayStartUnix: UInt64?,
    rangeStartUnix: UInt64? = nil,
    rangeEndUnix: UInt64? = nil
  ) async throws -> ServerUsageOverviewSnapshotPayload {
    var query: [URLQueryItem] = []
    if let todayStartUnix {
      query.append(URLQueryItem(name: "today_start_unix", value: String(todayStartUnix)))
    }
    if let rangeStartUnix {
      query.append(URLQueryItem(name: "range_start_unix", value: String(rangeStartUnix)))
    }
    if let rangeEndUnix {
      query.append(URLQueryItem(name: "range_end_unix", value: String(rangeEndUnix)))
    }
    return try await http.get("/api/usage/overview", query: query)
  }

  func fetchUsageBreakdown(
    groupBy: ServerUsageBreakdownGroupBy,
    startUnix: UInt64? = nil,
    endUnix: UInt64? = nil
  ) async throws -> ServerUsageBreakdownSnapshotPayload {
    var query = [URLQueryItem(name: "group_by", value: groupBy.rawValue)]
    if let startUnix {
      query.append(URLQueryItem(name: "start_unix", value: String(startUnix)))
    }
    if let endUnix {
      query.append(URLQueryItem(name: "end_unix", value: String(endUnix)))
    }
    return try await http.get("/api/usage/breakdown", query: query)
  }

  func fetchUsageSessions(
    startUnix: UInt64? = nil,
    endUnix: UInt64? = nil,
    limit: Int? = nil,
    offset: UInt64? = nil
  ) async throws -> ServerUsageSessionsSnapshotPayload {
    var query: [URLQueryItem] = []
    if let startUnix {
      query.append(URLQueryItem(name: "start_unix", value: String(startUnix)))
    }
    if let endUnix {
      query.append(URLQueryItem(name: "end_unix", value: String(endUnix)))
    }
    if let limit {
      query.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    if let offset {
      query.append(URLQueryItem(name: "offset", value: String(offset)))
    }
    return try await http.get("/api/usage/sessions", query: query)
  }

  func fetchSessionUsageTurns(
    sessionId: String,
    beforeTurnSeq: UInt64? = nil,
    limit: Int? = nil
  ) async throws -> ServerSessionUsageTurnsPagePayload {
    var query: [URLQueryItem] = []
    if let beforeTurnSeq {
      query.append(URLQueryItem(name: "before_turn_seq", value: String(beforeTurnSeq)))
    }
    if let limit {
      query.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    return try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/usage/turns",
      query: query
    )
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
