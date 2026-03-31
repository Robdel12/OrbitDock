@testable import OrbitDock
import Testing

struct ControlDeckSkillResolverTests {
  @Test func resolveSkillRefsMergesSelectedPathsAndInlineTokens() {
    let skills = sampleSkills

    let resolved = ControlDeckSkillResolver.resolveSkillRefs(
      content: "Please run $ship before release.",
      selectedSkillPaths: Set(["/skills/build"]),
      availableSkills: skills
    )

    #expect(resolved.map(\.name) == ["build", "ship"])
    #expect(resolved.map(\.path) == ["/skills/build", "/skills/ship"])
  }

  @Test func matchedSkillPathsTracksInlineTokensCaseInsensitively() {
    let matched = ControlDeckSkillResolver.matchedSkillPaths(
      in: "Use $BUILD and $ship.",
      availableSkills: sampleSkills
    )

    #expect(matched == Set(["/skills/build", "/skills/ship"]))
  }

  private var sampleSkills: [ControlDeckSkill] {
    [
      ControlDeckSkill(
        name: "build",
        path: "/skills/build",
        description: "Build the project",
        shortDescription: nil
      ),
      ControlDeckSkill(
        name: "ship",
        path: "/skills/ship",
        description: "Ship the project",
        shortDescription: nil
      ),
    ]
  }
}
