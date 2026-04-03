import Observation

@MainActor
@Observable
final class McpServersTabViewModel {
  var currentSessionId: String?
  var currentSessionStore: SessionStore?
  var expandedServers: Set<String> = []

  var startupState: McpStartupState? {
    currentSession?.mcpStartupState
  }

  var tools: [String: ServerMcpTool] {
    currentSession?.mcpTools ?? [:]
  }

  var authStatuses: [String: ServerMcpAuthStatus] {
    currentSession?.mcpAuthStatuses ?? [:]
  }

  var resources: [String: [ServerMcpResource]] {
    currentSession?.mcpResources ?? [:]
  }

  var resourceTemplates: [String: [ServerMcpResourceTemplate]] {
    currentSession?.mcpResourceTemplates ?? [:]
  }

  var provider: Provider? {
    currentSession?.provider
  }

  var capabilityNotice: McpCapabilityNotice? {
    guard let provider, let currentSessionStore else { return nil }
    return McpServersTabPlanner.capabilityNotice(
      provider: provider,
      codexAccountStatus: currentSessionStore.codexAccountStatus
    )
  }

  var serverEntries: [ServerEntry] {
    var names = Set<String>()

    if let state = startupState {
      names.formUnion(state.serverStatuses.keys)
      names.formUnion(state.readyServers)
      names.formUnion(state.failedServers.map(\.server))
      names.formUnion(state.cancelledServers)
    }

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
        error: errorForServer(name)
      )
    }
    .sorted { lhs, rhs in
      lhs.sortOrder < rhs.sortOrder
    }
  }

  func bind(sessionId: String, sessionStore: SessionStore) {
    currentSessionId = sessionId
    currentSessionStore = sessionStore
  }

  func refreshMcpServers() async {
    guard let currentSessionId, let currentSessionStore else { return }
    let capabilities = CapabilitiesService(sessionStore: currentSessionStore)
    try? await capabilities.refreshMcpServers(sessionId: currentSessionId)
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

  private var currentSession: SessionObservable? {
    guard let currentSessionId, let currentSessionStore else { return nil }
    return currentSessionStore.session(currentSessionId)
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
    if let state = startupState {
      if let status = state.serverStatuses[name] {
        switch status {
          case .ready: return .ready
          case .starting: return .starting
          case .connecting: return .connecting
          case .needsAuth: return .needsAuth
          case .failed: return .failed
          case .cancelled: return .cancelled
        }
      }
      if state.readyServers.contains(name) { return .ready }
      if state.failedServers.contains(where: { $0.server == name }) { return .failed }
      if state.cancelledServers.contains(name) { return .cancelled }
    }

    if !toolsForServer(name).isEmpty || !resourcesForServer(name).isEmpty || !resourceTemplatesForServer(name).isEmpty {
      return .ready
    }
    return .starting
  }

  private func errorForServer(_ name: String) -> String? {
    if let state = startupState {
      if case let .failed(error) = state.serverStatuses[name] {
        return error
      }
      if let failure = state.failedServers.first(where: { $0.server == name }) {
        return failure.error
      }
    }
    return nil
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
