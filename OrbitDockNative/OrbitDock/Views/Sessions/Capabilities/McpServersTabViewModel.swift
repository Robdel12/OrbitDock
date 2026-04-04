import Observation

@MainActor
@Observable
final class McpServersTabViewModel {
  var currentSessionId: String?
  var currentSessionStore: SessionStore?
  var expandedServers: Set<String> = []

  // Snapshot state — owned by this VM, populated via HTTP
  private var _tools: [String: ServerMcpTool] = [:]
  private var _resources: [String: [ServerMcpResource]] = [:]
  private var _resourceTemplates: [String: [ServerMcpResourceTemplate]] = [:]
  private var _authStatuses: [String: ServerMcpAuthStatus] = [:]
  private var _provider: Provider?

  var tools: [String: ServerMcpTool] { _tools }
  var authStatuses: [String: ServerMcpAuthStatus] { _authStatuses }
  var resources: [String: [ServerMcpResource]] { _resources }
  var resourceTemplates: [String: [ServerMcpResourceTemplate]] { _resourceTemplates }
  var provider: Provider? { _provider }

  var capabilityNotice: McpCapabilityNotice? {
    guard let provider, let currentSessionStore else { return nil }
    return McpServersTabPlanner.capabilityNotice(
      provider: provider,
      codexAccountStatus: currentSessionStore.codexAccountStatus
    )
  }

  var serverEntries: [ServerEntry] {
    var names = Set<String>()

    for key in tools.keys {
      if let server = extractServerName(from: key) {
        names.insert(server)
      }
    }
    names.formUnion(resources.keys)
    names.formUnion(resourceTemplates.keys)

    return names.map { name in
      ServerEntry(
        name: name,
        status: serverStatus(for: name),
        tools: toolsForServer(name),
        resources: resourcesForServer(name),
        resourceTemplates: resourceTemplatesForServer(name),
        authStatus: authStatuses[name],
        error: nil
      )
    }
    .sorted { lhs, rhs in
      lhs.sortOrder < rhs.sortOrder
    }
  }

  func bind(sessionId: String, sessionStore: SessionStore, provider: Provider? = nil) {
    currentSessionId = sessionId
    currentSessionStore = sessionStore
    if let provider { _provider = provider }
  }

  @ObservationIgnored private var isRefreshing = false
  @ObservationIgnored private var refreshQueued = false

  func refresh() async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    if isRefreshing { refreshQueued = true; return }
    isRefreshing = true
    defer {
      isRefreshing = false
      if refreshQueued { refreshQueued = false; Task { await refresh() } }
    }
    do {
      let response = try await store.clients.mcp.listTools(sessionId: sessionId)
      _tools = response.tools
      _resources = response.resources
      _resourceTemplates = response.resourceTemplates
      _authStatuses = response.authStatuses
    } catch {
      // Non-fatal
    }
  }

  func refreshMcpServers() async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    try? await store.clients.mcp.refreshServers(sessionId: sessionId)
    await refresh()
  }

  func toggleServerExpansion(_ serverName: String) {
    if expandedServers.contains(serverName) {
      expandedServers.remove(serverName)
    } else {
      expandedServers.insert(serverName)
    }
  }

  func isServerExpanded(_ serverName: String) -> Bool {
    expandedServers.contains(serverName)
  }

  private func extractServerName(from toolKey: String) -> String? {
    let parts = toolKey.split(separator: "__")
    guard parts.count >= 2 else { return nil }
    if parts[0] == "mcp" {
      return String(parts[1])
    }
    return String(parts[0])
  }

  private func toolsForServer(_ server: String) -> [ServerMcpTool] {
    tools.compactMap { key, tool in
      if let name = extractServerName(from: key), name == server {
        return tool
      }
      return nil
    }
    .sorted { $0.name < $1.name }
  }

  private func resourcesForServer(_ server: String) -> [ServerMcpResource] {
    (resources[server] ?? []).sorted { $0.name < $1.name }
  }

  private func resourceTemplatesForServer(_ server: String) -> [ServerMcpResourceTemplate] {
    (resourceTemplates[server] ?? []).sorted { $0.name < $1.name }
  }

  private func serverStatus(for name: String) -> ServerEntryStatus {
    if !toolsForServer(name).isEmpty || !resourcesForServer(name).isEmpty || !resourceTemplatesForServer(name).isEmpty {
      return .ready
    }
    return .starting
  }
}

// MARK: - Models

enum ServerEntryStatus: Int, Comparable {
  case ready = 0
  case starting = 1
  case connecting = 2
  case needsAuth = 3
  case failed = 4
  case cancelled = 5

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

struct ServerEntry: Identifiable {
  let name: String
  let status: ServerEntryStatus
  let tools: [ServerMcpTool]
  let resources: [ServerMcpResource]
  let resourceTemplates: [ServerMcpResourceTemplate]
  let authStatus: ServerMcpAuthStatus?
  let error: String?

  var id: String {
    name
  }

  var sortOrder: Int {
    status.rawValue
  }

  var hasExpandedContent: Bool {
    !tools.isEmpty || !resources.isEmpty || !resourceTemplates.isEmpty
  }

  var capabilitySummary: String {
    [
      tools.isEmpty ? nil : "\(tools.count) tool\(tools.count == 1 ? "" : "s")",
      resources.isEmpty ? nil : "\(resources.count) resource\(resources.count == 1 ? "" : "s")",
      resourceTemplates.isEmpty ? nil : "\(resourceTemplates.count) template\(resourceTemplates.count == 1 ? "" : "s")",
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }
}
