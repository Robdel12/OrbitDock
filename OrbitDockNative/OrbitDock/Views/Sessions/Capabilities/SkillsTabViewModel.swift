import Observation

@MainActor
@Observable
final class SkillsTabViewModel {
  private let scopeOrder: [ServerSkillScope] = [.repo, .user, .system, .admin]

  var currentSessionId: String?
  var currentSessionStore: SessionStore?

  // Snapshot state — owned by this VM, populated via HTTP
  private var _skills: [ServerSkillMetadata] = []
  private var _claudeSkillNames: [String] = []

  var skills: [ServerSkillMetadata] {
    _skills.filter(\.enabled)
  }

  var claudeSkillNames: [String] {
    _claudeSkillNames.sorted()
  }

  var groupedSkills: [(scope: ServerSkillScope, skills: [ServerSkillMetadata])] {
    scopeOrder.compactMap { scope in
      let matching = skills.filter { $0.scope == scope }
      guard !matching.isEmpty else { return nil }
      return (scope, matching)
    }
  }

  func bind(sessionId: String, sessionStore: SessionStore) {
    currentSessionId = sessionId
    currentSessionStore = sessionStore
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
      let response = try await store.clients.skills.listSkills(sessionId: sessionId)
      _skills = response.skills.flatMap(\.skills)
    } catch {
      // Non-fatal
    }
  }

  func refreshSkills() async {
    guard let sessionId = currentSessionId, let store = currentSessionStore else { return }
    _ = try? await store.clients.skills.listSkills(sessionId: sessionId, forceReload: true)
    await refresh()
  }

  func toggleSkillSelection(_ skillPath: String, selectedSkills: Set<String>) -> Set<String> {
    var updated = selectedSkills
    if updated.contains(skillPath) {
      updated.remove(skillPath)
    } else {
      updated.insert(skillPath)
    }
    return updated
  }
}
