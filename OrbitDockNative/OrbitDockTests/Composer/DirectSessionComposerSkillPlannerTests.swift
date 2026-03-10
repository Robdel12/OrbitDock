@testable import OrbitDock
import Testing

struct DirectSessionComposerSkillPlannerTests {
  @Test func inlineSkillNamesReturnOnlyKnownSkills() {
    let names = DirectSessionComposerSkillPlanner.inlineSkillNames(
      in: "Use $build. Ignore $unknown and also $ship.",
      availableSkillNames: ["build", "ship"]
    )

    #expect(names == ["build", "ship"])
  }

  @Test func resolveSkillInputsMergesSelectedAndInlineSkillsDeterministically() {
    let availableSkills = [
      ServerSkillMetadata(
        name: "build",
        description: "Build the project",
        shortDescription: nil,
        path: "/skills/build",
        scope: .repo,
        enabled: true
      ),
      ServerSkillMetadata(
        name: "ship",
        description: "Ship the project",
        shortDescription: nil,
        path: "/skills/ship",
        scope: .repo,
        enabled: true
      ),
      ServerSkillMetadata(
        name: "disabled",
        description: "Disabled skill",
        shortDescription: nil,
        path: "/skills/disabled",
        scope: .repo,
        enabled: false
      ),
    ]

    let resolved = DirectSessionComposerSkillPlanner.resolveSkillInputs(
      content: "Use $ship and $build before release.",
      selectedSkillPaths: ["/skills/build", "/skills/disabled"],
      availableSkills: availableSkills
    )

    #expect(resolved.map(\.name) == ["build", "ship"])
    #expect(resolved.map(\.path) == ["/skills/build", "/skills/ship"])
  }
}
