import Foundation

enum ControlDeckSkillResolver {
  static func resolveSkillRefs(
    content: String,
    selectedSkillPaths: Set<String>,
    availableSkills: [ControlDeckSkill]
  ) -> [ServerControlDeckSkillRef] {
    guard !availableSkills.isEmpty else { return [] }

    let inlineNames = Set(
      ControlDeckTextEditing.inlineSkillNames(
        in: content,
        availableSkillNames: availableSkills.map(\.name)
      ).map { $0.lowercased() }
    )

    return availableSkills
      .filter { selectedSkillPaths.contains($0.path) || inlineNames.contains($0.name.lowercased()) }
      .map { skill in
        ServerControlDeckSkillRef(name: skill.name, path: skill.path)
      }
  }

  static func matchedSkillPaths(
    in content: String,
    availableSkills: [ControlDeckSkill]
  ) -> Set<String> {
    guard !availableSkills.isEmpty else { return [] }

    let inlineNames = Set(
      ControlDeckTextEditing.inlineSkillNames(
        in: content,
        availableSkillNames: availableSkills.map(\.name)
      ).map { $0.lowercased() }
    )

    return Set(
      availableSkills.compactMap { skill in
        inlineNames.contains(skill.name.lowercased()) ? skill.path : nil
      }
    )
  }
}
