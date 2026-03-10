import Foundation

struct McpClient: Sendable {
  struct ToolsResponse: Decodable {
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

  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func listTools(sessionId: String) async throws -> ToolsResponse {
    try await http.get("/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/mcp/tools")
  }

  func refreshServers(sessionId: String) async throws {
    try await http.sendVoid(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/mcp/refresh",
      method: "POST",
      body: ServerEmptyBody()
    )
  }

  func toggleServer(sessionId: String, serverName: String, enabled: Bool) async throws {
    struct Body: Encodable { let serverName: String; let enabled: Bool }
    try await http.sendVoid(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/mcp/toggle",
      method: "POST",
      body: Body(serverName: serverName, enabled: enabled)
    )
  }

  func authenticate(sessionId: String, serverName: String) async throws {
    struct Body: Encodable { let serverName: String }
    try await http.sendVoid(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/mcp/authenticate",
      method: "POST",
      body: Body(serverName: serverName)
    )
  }

  func clearAuth(sessionId: String, serverName: String) async throws {
    struct Body: Encodable { let serverName: String }
    try await http.sendVoid(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/mcp/clear-auth",
      method: "POST",
      body: Body(serverName: serverName)
    )
  }

  func setServers(sessionId: String, config: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: config)
    try await http.sendVoidRaw(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/mcp/servers",
      method: "POST",
      bodyData: data
    )
  }
}
