import Foundation

@MainActor
extension SessionStore {
  func routeCapabilitiesEvent(_ event: ServerEvent) -> Bool {
    switch event {
      case let .skillsList(sessionId, skills, _):
        handleSkillsList(sessionId: sessionId, skills: skills)
        return true
      case .skillsUpdateAvailable(_):
        return true
      case let .mcpToolsList(sessionId, tools, resources, resourceTemplates, authStatuses):
        handleMcpToolsList(
          sessionId: sessionId,
          tools: tools,
          resources: resources,
          resourceTemplates: resourceTemplates,
          authStatuses: authStatuses
        )
        return true
      case let .mcpStartupUpdate(sessionId, server, status):
        handleMcpStartupUpdate(sessionId: sessionId, server: server, status: status)
        return true
      case let .mcpStartupComplete(sessionId, ready, failed, cancelled):
        handleMcpStartupComplete(
          sessionId: sessionId,
          ready: ready,
          failed: failed,
          cancelled: cancelled
        )
        return true
      case let .claudeCapabilities(sessionId, slashCommands, skills, tools, _):
        handleClaudeCapabilities(
          sessionId: sessionId,
          slashCommands: slashCommands,
          skills: skills,
          tools: tools
        )
        return true
      default:
        return false
    }
  }

  func handleSkillsList(sessionId: String, skills: [ServerSkillsListEntry]) {
    session(sessionId).skills = skills.flatMap(\.skills)
  }

  func handleMcpToolsList(
    sessionId: String,
    tools: [String: ServerMcpTool],
    resources: [String: [ServerMcpResource]],
    resourceTemplates: [String: [ServerMcpResourceTemplate]],
    authStatuses: [String: ServerMcpAuthStatus]
  ) {
    let obs = session(sessionId)
    obs.mcpTools = tools
    obs.mcpResources = resources
    obs.mcpResourceTemplates = resourceTemplates
    obs.mcpAuthStatuses = authStatuses
  }

  func handleMcpStartupUpdate(
    sessionId: String,
    server: String,
    status: ServerMcpStartupStatus
  ) {
    var startupState = ensureMcpStartupState(for: sessionId)
    startupState.serverStatuses[server] = status
    session(sessionId).mcpStartupState = startupState
  }

  func handleMcpStartupComplete(
    sessionId: String,
    ready: [String],
    failed: [ServerMcpStartupFailure],
    cancelled: [String]
  ) {
    var startupState = ensureMcpStartupState(for: sessionId)
    startupState.isComplete = true
    startupState.readyServers = ready
    startupState.failedServers = failed
    startupState.cancelledServers = cancelled
    session(sessionId).mcpStartupState = startupState
  }

  func handleClaudeCapabilities(
    sessionId: String,
    slashCommands: [String],
    skills: [String],
    tools: [String]
  ) {
    let obs = session(sessionId)
    obs.slashCommands = Set(slashCommands)
    obs.claudeSkillNames = skills
    obs.claudeToolNames = tools
  }

  private func ensureMcpStartupState(for sessionId: String) -> McpStartupState {
    let observable = session(sessionId)
    if let startupState = observable.mcpStartupState {
      return startupState
    }
    let startupState = McpStartupState()
    observable.mcpStartupState = startupState
    return startupState
  }
}
