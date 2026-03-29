import Foundation

struct ServerUpdateClient: Sendable {
  private struct SetUpdateChannelRequest: Encodable {
    let channel: String
  }

  private struct StartUpgradeRequest: Encodable {
    let restart: Bool
    let channel: String?
    let version: String?
  }

  private let http: ServerHTTPClient
  private let baseURL: URL
  private let authToken: String?

  init(http: ServerHTTPClient, baseURL: URL, authToken: String?) {
    self.http = http
    self.baseURL = baseURL
    self.authToken = authToken
  }

  func fetchServerMeta() async throws -> ServerMetaResponse {
    try await http.get("/api/server/meta")
  }

  func fetchUpdateStatus() async throws -> ServerUpdateStatus? {
    try await http.get("/api/server/update-status")
  }

  func checkForUpdates() async throws -> ServerUpdateCheckResponse {
    try await http.post("/api/server/check-update", body: EmptyRequestBody())
  }

  func fetchUpdateChannel() async throws -> ServerUpdateChannelResponse {
    try await http.get("/api/server/update-channel")
  }

  func setUpdateChannel(_ channel: String) async throws -> ServerUpdateCheckResponse {
    try await http.request(
      path: "/api/server/update-channel",
      method: "PUT",
      body: SetUpdateChannelRequest(channel: channel)
    )
  }

  func startUpgrade(
    restart: Bool = true,
    channel: String? = nil,
    version: String? = nil
  ) async throws -> ServerUpgradeStartResponse {
    try await http.request(
      path: "/api/server/start-upgrade",
      method: "POST",
      body: StartUpgradeRequest(restart: restart, channel: channel, version: version)
    )
  }

  func fetchHealth() async throws -> ServerHealthResponse {
    var request = URLRequest(url: baseURL.appending(path: "health"))
    request.httpMethod = "GET"
    request.timeoutInterval = 10
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }

    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(ServerHealthResponse.self, from: data)
  }
}

private struct EmptyRequestBody: Encodable {}
