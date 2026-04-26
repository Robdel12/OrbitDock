import Foundation
import Observation

enum SessionCapabilitiesSection: String, CaseIterable, Identifiable {
  case skills
  case plugins
  case mcp

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .skills:
      "Skills"
    case .plugins:
      "Plugins"
    case .mcp:
      "MCP"
    }
  }

  var refreshTitle: String {
    switch self {
    case .skills:
      "Refresh Skills"
    case .plugins:
      "Refresh Plugins"
    case .mcp:
      "Refresh MCP"
    }
  }

  var emptyTitle: String {
    switch self {
    case .skills:
      "No skills discovered"
    case .plugins:
      "No plugin marketplaces available"
    case .mcp:
      "No MCP servers reported"
    }
  }
}

struct SessionCapabilitiesMcpServer: Identifiable {
  let name: String
  let authStatus: ServerMcpAuthStatus?
  let tools: [ServerMcpTool]
  let resources: [ServerMcpResource]
  let resourceTemplates: [ServerMcpResourceTemplate]

  var id: String {
    name
  }
}

@MainActor
@Observable
final class SessionCapabilitiesModel {
  var selectedSection: SessionCapabilitiesSection = .skills
  var sessionState: ServerSessionState?
  var skills: [ServerSkillsListEntry] = []
  var skillErrors: [ServerSkillErrorInfo] = []
  var marketplaces: [ServerPluginMarketplaceEntry] = []
  var pluginLoadErrors: [ServerPluginMarketplaceLoadError] = []
  var featuredPluginIDs: Set<String> = []
  var mcpServers: [SessionCapabilitiesMcpServer] = []
  var installingPluginIDs: Set<String> = []
  var uninstallingPluginIDs: Set<String> = []
  var authenticatingMcpServerNames: Set<String> = []
  var lastError: String?
  var notice: String?
  var visibleSections: Set<SessionCapabilitiesSection> = []
  var loadedSections: Set<SessionCapabilitiesSection> = []
  var loadingSections: Set<SessionCapabilitiesSection> = []
  var staleSections: Set<SessionCapabilitiesSection> = []

  @ObservationIgnored private var loadGenerations: [SessionCapabilitiesSection: Int] = [:]

  func reset() {
    selectedSection = .skills
    sessionState = nil
    skills = []
    skillErrors = []
    marketplaces = []
    pluginLoadErrors = []
    featuredPluginIDs = []
    mcpServers = []
    installingPluginIDs = []
    uninstallingPluginIDs = []
    authenticatingMcpServerNames = []
    lastError = nil
    notice = nil
    visibleSections = []
    loadedSections = []
    loadingSections = []
    staleSections = []
    loadGenerations = [:]
  }

  func setVisible(_ visible: Bool, section: SessionCapabilitiesSection) {
    if visible {
      visibleSections.insert(section)
    } else {
      visibleSections.remove(section)
    }
  }

  func syncSessionState(_ state: ServerSessionState?) {
    sessionState = state
  }

  func hasLoaded(_ section: SessionCapabilitiesSection) -> Bool {
    loadedSections.contains(section)
  }

  func isLoading(_ section: SessionCapabilitiesSection) -> Bool {
    loadingSections.contains(section)
  }

  func isStale(_ section: SessionCapabilitiesSection) -> Bool {
    staleSections.contains(section)
  }

  func loadIfNeeded(
    session: ServerSessionContext,
    projectPath: String,
    sessionState: ServerSessionState?,
    section: SessionCapabilitiesSection
  ) async {
    syncSessionState(sessionState)
    guard !isLoading(section) else { return }
    guard !hasLoaded(section) || isStale(section) else { return }
    await refresh(
      session: session,
      projectPath: projectPath,
      sessionState: sessionState,
      section: section
    )
  }

  func refreshCurrentSection(
    session: ServerSessionContext,
    projectPath: String,
    sessionState: ServerSessionState?,
    forceReload: Bool = false
  ) async {
    await refresh(
      session: session,
      projectPath: projectPath,
      sessionState: sessionState,
      section: selectedSection,
      forceReload: forceReload
    )
  }

  func refresh(
    session: ServerSessionContext,
    projectPath: String,
    sessionState: ServerSessionState?,
    section: SessionCapabilitiesSection,
    forceReload: Bool = false
  ) async {
    syncSessionState(sessionState)

    switch section {
    case .skills:
      await refreshSkills(
        session: session,
        section: section,
        forceReload: forceReload
      )
    case .plugins:
      await refreshPlugins(
        session: session,
        projectPath: projectPath,
        section: section
      )
    case .mcp:
      await refreshMcpInventory(session: session, section: section)
    }
  }

  func markStale(_ section: SessionCapabilitiesSection) {
    staleSections.insert(section)
  }

  func markWorkspaceStale() {
    staleSections.formUnion(SessionCapabilitiesSection.allCases)
  }

  func installPlugin(
    marketplace: ServerPluginMarketplaceEntry,
    plugin: ServerPluginSummary,
    session: ServerSessionContext,
    projectPath: String
  ) async {
    guard plugin.installPolicy != .notAvailable else { return }

    installingPluginIDs.insert(plugin.id)
    defer { installingPluginIDs.remove(plugin.id) }

    do {
      let response = try await session.api.installPlugin(
        marketplacePath: marketplace.path,
        remoteMarketplaceName: marketplace.path == nil ? marketplace.name : nil,
        pluginName: plugin.name
      )
      notice = Self.installNotice(response: response, pluginName: plugin.name)
      await refresh(
        session: session,
        projectPath: projectPath,
        sessionState: self.sessionState,
        section: .plugins,
        forceReload: true
      )
      staleSections.formUnion([.skills, .mcp])
    } catch {
      lastError = error.localizedDescription
    }
  }

  func uninstallPlugin(
    plugin: ServerPluginSummary,
    session: ServerSessionContext,
    projectPath: String
  ) async {
    uninstallingPluginIDs.insert(plugin.id)
    defer { uninstallingPluginIDs.remove(plugin.id) }

    do {
      try await session.api.uninstallPlugin(pluginId: plugin.id)
      notice = "\(displayName(for: plugin)) removed."
      await refresh(
        session: session,
        projectPath: projectPath,
        sessionState: self.sessionState,
        section: .plugins,
        forceReload: true
      )
      staleSections.formUnion([.skills, .mcp])
    } catch {
      lastError = error.localizedDescription
    }
  }

  func refreshMcp(
    session: ServerSessionContext,
    projectPath: String
  ) async {
    guard !isLoading(.mcp) else { return }

    do {
      try await session.api.refreshMcp()
      notice = "Requested an MCP refresh."
      markStale(.mcp)
      await loadIfNeeded(
        session: session,
        projectPath: projectPath,
        sessionState: self.sessionState,
        section: .mcp
      )
    } catch {
      lastError = error.localizedDescription
    }
  }

  func authenticateMcp(
    server: SessionCapabilitiesMcpServer,
    session: ServerSessionContext,
    projectPath: String
  ) async {
    guard server.authStatus == .notLoggedIn else { return }
    guard !authenticatingMcpServerNames.contains(server.name) else { return }

    authenticatingMcpServerNames.insert(server.name)
    defer { authenticatingMcpServerNames.remove(server.name) }

    do {
      let response = try await session.api.authenticateMcp(serverName: server.name)
      if let urlString = response.authorizationURL,
        let url = URL(string: urlString),
        Platform.services.openURL(url)
      {
        notice = "Opened sign-in for \(server.name). Refresh MCP after auth completes."
      } else {
        notice = "Started auth for \(server.name)."
      }
      markStale(.mcp)
    } catch {
      lastError = error.localizedDescription
    }
  }

  func isFeatured(_ plugin: ServerPluginSummary) -> Bool {
    featuredPluginIDs.contains(plugin.id)
  }

  func displayName(for plugin: ServerPluginSummary) -> String {
    plugin.interface?.displayName ?? plugin.name
  }

  private func refreshSkills(
    session: ServerSessionContext,
    section: SessionCapabilitiesSection,
    forceReload: Bool
  ) async {
    let generation = beginLoading(section)
    defer { finishLoading(section, generation: generation) }

    do {
      let response = try await session.api.listSkills(forceReload: forceReload)
      guard isCurrent(section, generation: generation) else { return }
      skills = response.skills
      skillErrors = response.errors + response.skills.flatMap(\.errors)
      loadedSections.insert(section)
      staleSections.remove(section)
    } catch {
      guard isCurrent(section, generation: generation) else { return }
      lastError = error.localizedDescription
    }
  }

  private func refreshPlugins(
    session: ServerSessionContext,
    projectPath: String,
    section: SessionCapabilitiesSection
  ) async {
    let generation = beginLoading(section)
    defer { finishLoading(section, generation: generation) }

    let cwdHints = projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? []
      : [projectPath]

    do {
      let response = try await session.api.listPlugins(cwds: cwdHints)
      guard isCurrent(section, generation: generation) else { return }
      marketplaces = response.marketplaces
      pluginLoadErrors = response.marketplaceLoadErrors
      featuredPluginIDs = Set(response.featuredPluginIDs)
      loadedSections.insert(section)
      staleSections.remove(section)
    } catch {
      guard isCurrent(section, generation: generation) else { return }
      lastError = error.localizedDescription
    }
  }

  private func refreshMcpInventory(
    session: ServerSessionContext,
    section: SessionCapabilitiesSection
  ) async {
    let generation = beginLoading(section)
    defer { finishLoading(section, generation: generation) }

    do {
      let response = try await session.api.listMcp()
      guard isCurrent(section, generation: generation) else { return }
      mcpServers = Self.mapMcpServers(response)
      loadedSections.insert(section)
      staleSections.remove(section)
    } catch {
      guard isCurrent(section, generation: generation) else { return }
      lastError = error.localizedDescription
    }
  }

  private func beginLoading(_ section: SessionCapabilitiesSection) -> Int {
    lastError = nil
    loadingSections.insert(section)
    let nextGeneration = (loadGenerations[section] ?? 0) + 1
    loadGenerations[section] = nextGeneration
    return nextGeneration
  }

  private func finishLoading(_ section: SessionCapabilitiesSection, generation: Int) {
    guard isCurrent(section, generation: generation) else { return }
    loadingSections.remove(section)
  }

  private func isCurrent(_ section: SessionCapabilitiesSection, generation: Int) -> Bool {
    loadGenerations[section] == generation
  }

  private static func mapMcpServers(
    _ response: CapabilitiesClient.McpResponse
  ) -> [SessionCapabilitiesMcpServer] {
    let toolsByServer = Dictionary(grouping: response.tools) { key, _ in
      mcpServerName(for: key) ?? "unknown"
    }
    let names = Set(toolsByServer.keys)
      .union(response.resources.keys)
      .union(response.resourceTemplates.keys)
      .union(response.authStatuses.keys)

    return names.sorted().map { name in
      SessionCapabilitiesMcpServer(
        name: name,
        authStatus: response.authStatuses[name],
        tools: toolsByServer[name]?.map(\.value).sorted { $0.name < $1.name } ?? [],
        resources: response.resources[name] ?? [],
        resourceTemplates: response.resourceTemplates[name] ?? []
      )
    }
  }

  private static func mcpServerName(for toolName: String) -> String? {
    guard toolName.hasPrefix("mcp__") else { return nil }
    let remainder = toolName.dropFirst("mcp__".count)
    guard let separatorIndex = remainder.firstIndex(of: "_"),
      remainder.indices.contains(remainder.index(after: separatorIndex)),
      remainder[remainder.index(after: separatorIndex)] == "_"
    else {
      return nil
    }
    return String(remainder[..<separatorIndex])
  }

  private static func installNotice(
    response: CapabilitiesClient.PluginInstallResponse,
    pluginName: String
  ) -> String {
    guard !response.appsNeedingAuth.isEmpty else {
      return "\(pluginName) installed."
    }

    let appNames = response.appsNeedingAuth.map(\.name).joined(separator: ", ")
    return "\(pluginName) installed. \(appNames) \(response.authPolicy == .onInstall ? "need" : "may need") auth."
  }
}
