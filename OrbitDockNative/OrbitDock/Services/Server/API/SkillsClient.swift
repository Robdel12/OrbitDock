import Foundation

struct SkillsClient: Sendable {
  struct SkillsResponse: Decodable {
    let sessionId: String
    let skills: [ServerSkillsListEntry]
    let claudeSkillNames: [String]
    let errors: [ServerSkillErrorInfo]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case skills
      case claudeSkillNames = "claude_skill_names"
      case errors
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      sessionId = try container.decode(String.self, forKey: .sessionId)
      skills = try container.decodeIfPresent([ServerSkillsListEntry].self, forKey: .skills) ?? []
      claudeSkillNames =
        try container.decodeIfPresent([String].self, forKey: .claudeSkillNames) ?? []
      errors = try container.decodeIfPresent([ServerSkillErrorInfo].self, forKey: .errors) ?? []
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
    var query = cwds.map { URLQueryItem(name: "cwd", value: $0) }
    if forceReload { query.append(URLQueryItem(name: "force_reload", value: "true")) }
    return try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/skills",
      query: query
    )
  }
}
