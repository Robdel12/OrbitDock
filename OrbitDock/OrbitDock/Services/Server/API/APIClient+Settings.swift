import Foundation

extension APIClient {

  func setOpenAiKey(_ key: String) async throws {
    struct Body: Encodable { let key: String }
    struct Resp: Decodable { let configured: Bool }
    let _: Resp = try await post("/api/server/openai-key", body: Body(key: key))
  }

  func checkOpenAiKeyStatus() async throws -> Bool {
    struct Resp: Decodable { let configured: Bool }
    let resp: Resp = try await get("/api/server/openai-key")
    return resp.configured
  }

  func setServerRole(isPrimary: Bool) async throws -> Bool {
    struct Body: Encodable { let isPrimary: Bool }
    struct Resp: Decodable {
      let isPrimary: Bool
      enum CodingKeys: String, CodingKey { case isPrimary = "is_primary" }
    }
    let resp: Resp = try await request(
      path: "/api/server/role", method: "PUT",
      body: Body(isPrimary: isPrimary))
    return resp.isPrimary
  }

  func listRecentProjects() async throws -> [ServerRecentProject] {
    struct Resp: Decodable { let projects: [ServerRecentProject] }
    let resp: Resp = try await get("/api/fs/recent-projects")
    return resp.projects
  }

  func browseDirectory(path: String) async throws -> (String, [ServerDirectoryEntry]) {
    struct Resp: Decodable {
      let path: String
      let entries: [ServerDirectoryEntry]
    }
    let resp: Resp = try await get(
      "/api/fs/browse",
      query: [URLQueryItem(name: "path", value: path)])
    return (resp.path, resp.entries)
  }

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

  func listSkills(
    sessionId: String, cwds: [String] = [], forceReload: Bool = false
  ) async throws -> SkillsResponse {
    var query: [URLQueryItem] = []
    for cwd in cwds { query.append(URLQueryItem(name: "cwd", value: cwd)) }
    if forceReload { query.append(URLQueryItem(name: "force_reload", value: "true")) }
    return try await get("/api/sessions/\(encode(sessionId))/skills", query: query)
  }

  struct RemoteSkillsResponse: Decodable {
    let sessionId: String
    let skills: [ServerRemoteSkillSummary]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case skills
    }
  }

  func listRemoteSkills(sessionId: String) async throws -> RemoteSkillsResponse {
    try await get("/api/sessions/\(encode(sessionId))/skills/remote")
  }

  func downloadRemoteSkill(sessionId: String, hazelnutId: String) async throws {
    struct Body: Encodable { let hazelnutId: String }
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/skills/download", method: "POST",
      body: Body(hazelnutId: hazelnutId))
  }

  struct McpToolsResponse: Decodable {
    let sessionId: String
    let tools: [String: ServerMcpTool]
    let resources: [String: [ServerMcpResource]]
    let resourceTemplates: [String: [ServerMcpResourceTemplate]]
    let authStatuses: [String: ServerMcpAuthStatus]

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case tools
      case resources
      case resourceTemplates = "resource_templates"
      case authStatuses = "auth_statuses"
    }
  }

  func listMcpTools(sessionId: String) async throws -> McpToolsResponse {
    try await get("/api/sessions/\(encode(sessionId))/mcp/tools")
  }

  func refreshMcpServers(sessionId: String) async throws {
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/mcp/refresh", method: "POST",
      body: EmptyBody())
  }

  func toggleMcpServer(sessionId: String, serverName: String, enabled: Bool) async throws {
    struct Body: Encodable { let serverName: String; let enabled: Bool }
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/mcp/toggle", method: "POST",
      body: Body(serverName: serverName, enabled: enabled))
  }

  func mcpAuthenticate(sessionId: String, serverName: String) async throws {
    struct Body: Encodable { let serverName: String }
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/mcp/authenticate", method: "POST",
      body: Body(serverName: serverName))
  }

  func mcpClearAuth(sessionId: String, serverName: String) async throws {
    struct Body: Encodable { let serverName: String }
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/mcp/clear-auth", method: "POST",
      body: Body(serverName: serverName))
  }

  func mcpSetServers(sessionId: String, config: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: config)
    try await fireAndForgetRaw(
      "/api/sessions/\(encode(sessionId))/mcp/servers", method: "POST",
      bodyData: data)
  }

  func applyFlagSettings(sessionId: String, settings: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: settings)
    try await fireAndForgetRaw(
      "/api/sessions/\(encode(sessionId))/flags", method: "POST",
      bodyData: data)
  }

  func setClientPrimaryClaim(
    clientId: String, deviceName: String, isPrimary: Bool
  ) async throws {
    struct Body: Encodable {
      let clientId: String
      let deviceName: String
      let isPrimary: Bool
    }
    let _: AcceptedResponse = try await post(
      "/api/client/primary-claim",
      body: Body(clientId: clientId, deviceName: deviceName, isPrimary: isPrimary))
  }
}
