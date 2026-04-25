import Foundation

struct CapabilitiesClient: Sendable {
  private struct EmptyResponse: Decodable {}

  struct PluginsResponse: Decodable {
    let marketplaces: [ServerPluginMarketplaceEntry]
    let marketplaceLoadErrors: [ServerPluginMarketplaceLoadError]
    let featuredPluginIDs: [String]

    enum CodingKeys: String, CodingKey {
      case marketplaces
      case marketplaceLoadErrors = "marketplace_load_errors"
      case featuredPluginIDs = "featured_plugin_ids"
    }
  }

  struct PluginInstallRequest: Encodable {
    var marketplacePath: String?
    var remoteMarketplaceName: String?
    let pluginName: String

    enum CodingKeys: String, CodingKey {
      case marketplacePath = "marketplace_path"
      case remoteMarketplaceName = "remote_marketplace_name"
      case pluginName = "plugin_name"
    }
  }

  struct PluginInstallResponse: Decodable {
    let authPolicy: ServerPluginAuthPolicy
    let appsNeedingAuth: [ServerPluginAppSummary]

    enum CodingKeys: String, CodingKey {
      case authPolicy = "auth_policy"
      case appsNeedingAuth = "apps_needing_auth"
    }
  }

  struct PluginUninstallRequest: Encodable {
    let pluginId: String

    enum CodingKeys: String, CodingKey {
      case pluginId = "plugin_id"
    }
  }

  struct McpResponse: Decodable {
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

  func listPlugins(
    sessionId: String,
    cwds: [String] = []
  ) async throws -> PluginsResponse {
    let query = cwds.map { URLQueryItem(name: "cwd", value: $0) }
    return try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/plugins",
      query: query
    )
  }

  func installPlugin(
    sessionId: String,
    request: PluginInstallRequest
  ) async throws -> PluginInstallResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/plugins/install",
      body: request
    )
  }

  func uninstallPlugin(
    sessionId: String,
    pluginId: String
  ) async throws {
    let _: EmptyResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/plugins/uninstall",
      body: PluginUninstallRequest(pluginId: pluginId)
    )
  }

  func listMcp(sessionId: String) async throws -> McpResponse {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/mcp"
    )
  }

  func refreshMcp(sessionId: String) async throws {
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/mcp/refresh",
      body: ServerEmptyBody()
    )
  }
}
