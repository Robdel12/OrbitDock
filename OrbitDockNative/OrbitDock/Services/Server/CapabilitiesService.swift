import Foundation

@MainActor
final class CapabilitiesService {
  private let sessionStore: SessionStore

  init(sessionStore: SessionStore) {
    self.sessionStore = sessionStore
  }

  func listSkills(sessionId: String) async throws -> [ServerSkillMetadata] {
    let response = try await sessionStore.clients.skills.listSkills(sessionId: sessionId)
    let session = sessionStore.session(sessionId)
    session.skills = response.skills.flatMap(\.skills)
    return session.skills
  }

  func listMcpTools(sessionId: String) async throws {
    let response = try await sessionStore.clients.mcp.listTools(sessionId: sessionId)
    let session = sessionStore.session(sessionId)
    session.mcpTools = response.tools
    session.mcpResources = response.resources
    session.mcpResourceTemplates = response.resourceTemplates
    session.mcpAuthStatuses = response.authStatuses
  }

  func refreshMcpServers(sessionId: String) async throws {
    try await sessionStore.clients.mcp.refreshServers(sessionId: sessionId)
  }
}
