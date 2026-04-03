import Observation

@MainActor
@Observable
final class SkillsTabViewModel {
  private let scopeOrder: [ServerSkillScope] = [.repo, .user, .system, .admin]

  var currentSessionId: String?
  var currentSessionStore: SessionStore?

  var skills: [ServerSkillMetadata] {
    currentSession.flatMap { $0.skills.filter(\.enabled) } ?? []
  }

  var claudeSkillNames: [String] {
    (currentSession?.claudeSkillNames ?? []).sorted()
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

  func refreshSkills() async {
    guard let currentSessionId, let currentSessionStore else { return }
    let capabilities = CapabilitiesService(sessionStore: currentSessionStore)
    try? await capabilities.listSkills(sessionId: currentSessionId)
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

  private var currentSession: SessionObservable? {
    guard let currentSessionId, let currentSessionStore else { return nil }
    return currentSessionStore.session(currentSessionId)
  }
}
