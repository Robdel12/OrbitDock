import Foundation

enum DirectSessionComposerSkillPlanner {
  static func inlineSkillNames(
    in text: String,
    availableSkillNames: Set<String>
  ) -> [String] {
    var names: [String] = []

    for word in text.components(separatedBy: .whitespacesAndNewlines) {
      guard word.hasPrefix("$") else { continue }
      let raw = String(word.dropFirst())
      let name = raw.trimmingCharacters(in: .punctuationCharacters)
      guard availableSkillNames.contains(name) else { continue }
      names.append(name)
    }

    return names
  }

  static func resolveSkillInputs(
    content: String,
    selectedSkillPaths: Set<String>,
    availableSkills: [ServerSkillMetadata]
  ) -> [ServerSkillInput] {
    let inlineSkillNameSet = Set(
      inlineSkillNames(
        in: content,
        availableSkillNames: Set(availableSkills.map(\.name))
      )
    )
    var seenPaths = Set<String>()
    var resolved: [ServerSkillInput] = []

    for skill in availableSkills {
      guard skill.enabled else { continue }
      let isSelected = selectedSkillPaths.contains(skill.path)
      let isReferencedInline = inlineSkillNameSet.contains(skill.name)
      guard isSelected || isReferencedInline else { continue }
      guard seenPaths.insert(skill.path).inserted else { continue }
      resolved.append(ServerSkillInput(name: skill.name, path: skill.path))
    }

    return resolved
  }
}
