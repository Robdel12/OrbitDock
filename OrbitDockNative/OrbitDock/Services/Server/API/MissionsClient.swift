import Foundation

struct MissionsClient: Sendable {
  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  // MARK: - Mission CRUD

  func listMissions() async throws -> MissionsListResponse {
    try await http.get("/api/missions")
  }

  func getMission(_ id: String) async throws -> MissionDetailResponse {
    try await http.get("/api/missions/\(requestBuilder.encodePathComponent(id))")
  }

  func createMission(
    name: String,
    repoRoot: String,
    trackerKind: String,
    provider: String
  ) async throws -> MissionSummary {
    let body = CreateMissionRequest(
      name: name,
      repoRoot: repoRoot,
      trackerKind: trackerKind,
      provider: provider
    )
    return try await http.post("/api/missions", body: body)
  }

  func updateMission(
    _ id: String,
    name: String? = nil,
    enabled: Bool? = nil,
    paused: Bool? = nil
  ) async throws -> MissionOkResponse {
    let body = MissionUpdateBody(name: name, enabled: enabled, paused: paused)
    return try await http.request(
      path: "/api/missions/\(requestBuilder.encodePathComponent(id))",
      method: "PUT",
      body: body
    )
  }

  func updateMissionDetail(
    _ id: String,
    name: String? = nil,
    enabled: Bool? = nil,
    paused: Bool? = nil
  ) async throws -> MissionDetailResponse {
    let body = MissionUpdateBody(name: name, enabled: enabled, paused: paused)
    return try await http.request(
      path: "/api/missions/\(requestBuilder.encodePathComponent(id))",
      method: "PUT",
      body: body
    )
  }

  func deleteMission(_ id: String) async throws -> MissionsListResponse {
    try await http.request(
      path: "/api/missions/\(requestBuilder.encodePathComponent(id))",
      method: "DELETE"
    )
  }

  // MARK: - Mission Actions

  func scaffoldMission(_ id: String) async throws -> MissionDetailResponse {
    try await http.post(
      "/api/missions/\(requestBuilder.encodePathComponent(id))/scaffold",
      body: EmptyBody()
    )
  }

  func migrateWorkflow(_ id: String) async throws -> MissionDetailResponse {
    try await http.post(
      "/api/missions/\(requestBuilder.encodePathComponent(id))/migrate-workflow",
      body: EmptyBody()
    )
  }

  func startOrchestrator(_ id: String) async throws {
    let _: MissionOkResponse = try await http.post(
      "/api/missions/\(requestBuilder.encodePathComponent(id))/start-orchestrator",
      body: EmptyBody()
    )
  }

  func retryIssue(missionId: String, issueId: String) async throws {
    let _: MissionOkResponse = try await http.request(
      path: "/api/missions/\(requestBuilder.encodePathComponent(missionId))/issues/\(requestBuilder.encodePathComponent(issueId))/retry",
      method: "POST"
    )
  }

  // MARK: - Mission Settings

  func updateSettings(
    _ missionId: String,
    body: some Encodable
  ) async throws -> MissionSettingsUpdateResponse {
    try await http.request(
      path: "/api/missions/\(requestBuilder.encodePathComponent(missionId))/settings",
      method: "PUT",
      body: body
    )
  }

  // MARK: - Tracker Keys

  func getTrackerKeys() async throws -> TrackerKeysResponse {
    try await http.get("/api/server/tracker-keys")
  }

  func setLinearKey(_ key: String) async throws -> TrackerKeyResponse {
    try await http.post("/api/server/linear-key", body: SetTrackerKeyBody(key: key))
  }

  func deleteLinearKey() async throws -> TrackerKeyResponse {
    try await http.request(path: "/api/server/linear-key", method: "DELETE")
  }

  func setGitHubKey(_ key: String) async throws -> TrackerKeyResponse {
    try await http.post("/api/server/github-key", body: SetTrackerKeyBody(key: key))
  }

  func deleteGitHubKey() async throws -> TrackerKeyResponse {
    try await http.request(path: "/api/server/github-key", method: "DELETE")
  }

  // MARK: - Mission Defaults

  func getMissionDefaults() async throws -> MissionDefaultsResponse {
    try await http.get("/api/server/mission-defaults")
  }

  func updateMissionDefaults(
    providerStrategy: String,
    primaryProvider: String,
    secondaryProvider: String?
  ) async throws -> MissionDefaultsResponse {
    let body = UpdateMissionDefaultsBody(
      providerStrategy: providerStrategy,
      primaryProvider: primaryProvider,
      secondaryProvider: secondaryProvider
    )
    return try await http.request(
      path: "/api/server/mission-defaults",
      method: "PUT",
      body: body
    )
  }
}

// MARK: - Response Types

struct MissionSettingsUpdateResponse: Decodable {
  let summary: MissionSummary
  let settings: MissionSettings?
}

struct TrackerKeysResponse: Decodable {
  let linear: TrackerKeyInfo
  let github: TrackerKeyInfo

  struct TrackerKeyInfo: Decodable {
    let configured: Bool
    let source: String?
  }
}

struct MissionDefaultsResponse: Codable {
  let providerStrategy: String
  let primaryProvider: String
  let secondaryProvider: String?

  enum CodingKeys: String, CodingKey {
    case providerStrategy = "provider_strategy"
    case primaryProvider = "primary_provider"
    case secondaryProvider = "secondary_provider"
  }
}

private struct UpdateMissionDefaultsBody: Encodable {
  let providerStrategy: String
  let primaryProvider: String
  let secondaryProvider: String?

  enum CodingKeys: String, CodingKey {
    case providerStrategy = "provider_strategy"
    case primaryProvider = "primary_provider"
    case secondaryProvider = "secondary_provider"
  }
}
