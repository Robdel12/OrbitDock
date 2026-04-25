import Foundation
import Observation

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
  enum Tab: String, CaseIterable, Identifiable {
    case runtime
    case plugins
    case skills
    case mcp

    var id: String {
      rawValue
    }
  }

  var selectedTab: Tab = .runtime
  var sessionState: ServerSessionState?
  var controls: ServerSessionControlsPayload?
  var instructions: ServerSessionInstructionsPayload?
  var collaborationModes: [ServerSessionCollaborationMode] = []
  var skills: [ServerSkillsListEntry] = []
  var skillErrors: [ServerSkillErrorInfo] = []
  var marketplaces: [ServerPluginMarketplaceEntry] = []
  var pluginLoadErrors: [ServerPluginMarketplaceLoadError] = []
  var featuredPluginIDs: Set<String> = []
  var mcpServers: [SessionCapabilitiesMcpServer] = []
  var isLoading = false
  var isRefreshingMcp = false
  var isApplyingCollaboration = false
  var isInterrupting = false
  var isCompacting = false
  var isUndoing = false
  var isRollingBack = false
  var rollbackTurnCount = 1
  var installingPluginIDs: Set<String> = []
  var uninstallingPluginIDs: Set<String> = []
  var lastError: String?
  var notice: String?
  var hasLoaded = false
  var isStale = false

  @ObservationIgnored private var loadGeneration = 0

  func reset() {
    selectedTab = .runtime
    sessionState = nil
    controls = nil
    instructions = nil
    collaborationModes = []
    skills = []
    skillErrors = []
    marketplaces = []
    pluginLoadErrors = []
    featuredPluginIDs = []
    mcpServers = []
    isLoading = false
    isRefreshingMcp = false
    isApplyingCollaboration = false
    isInterrupting = false
    isCompacting = false
    isUndoing = false
    isRollingBack = false
    rollbackTurnCount = 1
    installingPluginIDs = []
    uninstallingPluginIDs = []
    lastError = nil
    notice = nil
    hasLoaded = false
    isStale = false
    loadGeneration += 1
  }

  func markStale() {
    isStale = true
  }

  func syncSessionState(_ state: ServerSessionState?) {
    sessionState = state
    clampRollbackTurnCount()
  }

  func loadIfNeeded(
    session: ServerSessionContext,
    projectPath: String,
    sessionState: ServerSessionState?
  ) async {
    syncSessionState(sessionState)
    guard !hasLoaded || isStale else { return }
    await refresh(session: session, projectPath: projectPath, sessionState: sessionState)
  }

  func refresh(
    session: ServerSessionContext,
    projectPath: String,
    sessionState: ServerSessionState?,
    forceSkillReload: Bool = false
  ) async {
    syncSessionState(sessionState)

    let generation = nextGeneration()
    isLoading = true
    lastError = nil

    let cwdHints = projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? []
      : [projectPath]

    async let instructionsTask = session.api.fetchSessionInstructions()
    async let controlsTask = session.api.fetchSessionControls()
    async let collaborationTask = session.api.listCollaborationModes()
    async let skillsTask = session.api.listSkills(forceReload: forceSkillReload)
    async let pluginsTask = session.api.listPlugins(cwds: cwdHints)
    async let mcpTask = session.api.listMcp()

    var capturedError: Error?

    var loadedInstructions: ServerSessionInstructionsPayload?
    do {
      let response = try await instructionsTask
      loadedInstructions = response.instructions
    } catch {
      capturedError = capturedError ?? error
    }

    var loadedControls: ServerSessionControlsPayload?
    do {
      loadedControls = try await controlsTask
    } catch {
      capturedError = capturedError ?? error
    }

    var loadedCollaborationModes: [ServerSessionCollaborationMode] = []
    do {
      loadedCollaborationModes = try await collaborationTask
    } catch {
      capturedError = capturedError ?? error
    }

    var loadedSkills: [ServerSkillsListEntry] = []
    var loadedSkillErrors: [ServerSkillErrorInfo] = []
    do {
      let response = try await skillsTask
      loadedSkills = response.skills
      loadedSkillErrors = response.errors + response.skills.flatMap(\.errors)
    } catch {
      capturedError = capturedError ?? error
    }

    var loadedMarketplaces: [ServerPluginMarketplaceEntry] = []
    var loadedPluginLoadErrors: [ServerPluginMarketplaceLoadError] = []
    var loadedFeaturedPluginIDs: Set<String> = []
    do {
      let response = try await pluginsTask
      loadedMarketplaces = response.marketplaces
      loadedPluginLoadErrors = response.marketplaceLoadErrors
      loadedFeaturedPluginIDs = Set(response.featuredPluginIDs)
    } catch {
      capturedError = capturedError ?? error
    }

    var loadedMcpServers: [SessionCapabilitiesMcpServer] = []
    do {
      let response = try await mcpTask
      loadedMcpServers = Self.mapMcpServers(response)
    } catch {
      capturedError = capturedError ?? error
    }

    guard generation == loadGeneration else { return }

    controls = loadedControls
    instructions = loadedInstructions
    collaborationModes = loadedCollaborationModes
    skills = loadedSkills
    skillErrors = loadedSkillErrors
    marketplaces = loadedMarketplaces
    pluginLoadErrors = loadedPluginLoadErrors
    featuredPluginIDs = loadedFeaturedPluginIDs
    mcpServers = loadedMcpServers
    hasLoaded = true
    isStale = false
    isLoading = false

    if let capturedError {
      lastError = capturedError.localizedDescription
    }
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
        forceSkillReload: true
      )
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
        forceSkillReload: true
      )
    } catch {
      lastError = error.localizedDescription
    }
  }

  func refreshMcp(
    session: ServerSessionContext,
    projectPath: String
  ) async {
    guard !isRefreshingMcp else { return }

    isRefreshingMcp = true
    defer { isRefreshingMcp = false }

    do {
      try await session.api.refreshMcp()
      notice = "Requested an MCP refresh."
      await refresh(session: session, projectPath: projectPath, sessionState: self.sessionState)
    } catch {
      lastError = error.localizedDescription
    }
  }

  func applyCollaborationMode(
    _ mode: ServerSessionCollaborationMode,
    session: ServerSessionContext
  ) async {
    await runAction(\.isApplyingCollaboration) {
      let payload = try await session.api.updateSessionConfig(collaborationMode: mode.name)
      await self.applyDetailSnapshot(payload, session: session)
      self.notice = "Switched collaboration to \(mode.name)."
    }
  }

  func interruptTurn(session: ServerSessionContext) async {
    await runAction(\.isInterrupting) {
      if let payload = try await session.api.stopActiveTurn() {
        await self.applyDetailSnapshot(payload, session: session)
      }
      self.notice = "Requested a turn stop."
    }
  }

  func compactContext(session: ServerSessionContext) async {
    await runAction(\.isCompacting) {
      if let payload = try await session.api.compactContext() {
        await self.applyDetailSnapshot(payload, session: session)
      }
      self.notice = "Requested context compaction."
    }
  }

  func undoLastTurn(session: ServerSessionContext) async {
    await runAction(\.isUndoing) {
      if let payload = try await session.api.undoLastTurn() {
        await self.applyDetailSnapshot(payload, session: session)
      }
      self.notice = "Requested undo."
    }
  }

  func rollbackTurns(session: ServerSessionContext) async {
    let turns = max(1, rollbackTurnCount)

    await runAction(\.isRollingBack) {
      if let payload = try await session.api.rollbackTurns(numTurns: UInt32(turns)) {
        await self.applyDetailSnapshot(payload, session: session)
      }
      self.notice = turns == 1 ? "Rolled back 1 turn." : "Rolled back \(turns) turns."
    }
  }

  func isFeatured(_ plugin: ServerPluginSummary) -> Bool {
    featuredPluginIDs.contains(plugin.id)
  }

  func displayName(for plugin: ServerPluginSummary) -> String {
    plugin.interface?.displayName ?? plugin.name
  }

  private func applyDetailSnapshot(
    _ payload: ServerSessionDetailSnapshotPayload,
    session: ServerSessionContext
  ) async {
    sessionState = payload.session
    clampRollbackTurnCount()
    await refreshControls(session: session)
    isStale = true
  }

  private func refreshControls(session: ServerSessionContext) async {
    do {
      controls = try await session.api.fetchSessionControls()
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func clampRollbackTurnCount() {
    let availableTurns = Int(sessionState?.turnCount ?? 1)
    rollbackTurnCount = max(1, min(rollbackTurnCount, max(1, availableTurns)))
  }

  private func nextGeneration() -> Int {
    loadGeneration += 1
    return loadGeneration
  }

  private func runAction(
    _ flag: ReferenceWritableKeyPath<SessionCapabilitiesModel, Bool>,
    operation: @escaping () async throws -> Void
  ) async {
    guard !self[keyPath: flag] else { return }

    self[keyPath: flag] = true
    defer { self[keyPath: flag] = false }

    do {
      try await operation()
    } catch {
      lastError = error.localizedDescription
    }
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
