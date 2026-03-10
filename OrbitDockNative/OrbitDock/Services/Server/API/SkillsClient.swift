import Foundation

struct SkillsClient: Sendable {
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

  struct RemoteSkillsResponse: Decodable {
    let sessionId: String
    let skills: [ServerRemoteSkillSummary]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case skills
    }
  }

  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func listSkills(
    sessionId: String,
    cwds: [String] = [],
    forceReload: Bool = false
  ) async throws -> SkillsResponse {
    var query: [URLQueryItem] = []
    for cwd in cwds { query.append(URLQueryItem(name: "cwd", value: cwd)) }
    if forceReload { query.append(URLQueryItem(name: "force_reload", value: "true")) }
    return try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/skills",
      query: query
    )
  }

  func listRemoteSkills(sessionId: String) async throws -> RemoteSkillsResponse {
    try await http.get("/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/skills/remote")
  }

  func downloadRemoteSkill(sessionId: String, hazelnutId: String) async throws {
    struct Body: Encodable { let hazelnutId: String }
    try await http.sendVoid(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/skills/download",
      method: "POST",
      body: Body(hazelnutId: hazelnutId)
    )
  }
}
