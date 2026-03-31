import Foundation

enum ControlDeckAutocompletePlanner {
  static let maxSuggestionCount = 12

  static func completionMode(for text: String) -> ControlDeckCompletionMode {
    if let mentionQuery = ControlDeckTextEditing.trailingTokenQuery(
      in: text,
      prefix: "@",
      requireWhitespaceBoundaryBeforePrefix: true
    ) {
      return .mention(query: mentionQuery)
    }

    if let skillQuery = ControlDeckTextEditing.trailingTokenQuery(in: text, prefix: "$") {
      // Keep the surface quiet on bare "$" so we do not flood the editor with the full list.
      guard !skillQuery.isEmpty else { return .inactive }
      return .skill(query: skillQuery)
    }

    return .inactive
  }

  static func skillSuggestions(
    for query: String,
    skills: [ControlDeckSkill]
  ) -> [ControlDeckCompletionSuggestion] {
    let normalizedQuery = query.lowercased()
    let matching = skills.compactMap { skill -> (skill: ControlDeckSkill, rank: Int)? in
      let name = skill.name.lowercased()
      if name.hasPrefix(normalizedQuery) {
        return (skill, 0)
      }
      if name.contains(normalizedQuery) {
        return (skill, 1)
      }
      return nil
    }
    .sorted { lhs, rhs in
      if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
      return lhs.skill.name.localizedCaseInsensitiveCompare(rhs.skill.name) == .orderedAscending
    }

    return matching.prefix(maxSuggestionCount).map { skill in
      ControlDeckCompletionSuggestion(
        id: skill.skill.id,
        kind: .skill,
        title: skill.skill.name,
        subtitle: skill.skill.shortDescription ?? skill.skill.description
      )
    }
  }
}
