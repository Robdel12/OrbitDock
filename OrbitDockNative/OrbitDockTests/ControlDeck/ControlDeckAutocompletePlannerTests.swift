@testable import OrbitDock
import Testing

@MainActor
struct ControlDeckAutocompletePlannerTests {
  @Test func completionModeActivatesForBareSkillPrefix() {
    let mode = ControlDeckAutocompletePlanner.completionMode(for: "$")
    #expect(mode == .skill(query: ""))
  }

  @Test func completionModeActivatesForSkillQuery() {
    let mode = ControlDeckAutocompletePlanner.completionMode(for: "$des")
    #expect(mode == .skill(query: "des"))
  }

  @Test func skillSuggestionsAreFilteredAndCapped() {
    let suggestions = ControlDeckAutocompletePlanner.skillSuggestions(
      for: "de",
      skills: [
        ControlDeckSkill(name: "deploy", path: "/skills/deploy", description: "", shortDescription: nil),
        ControlDeckSkill(name: "debug", path: "/skills/debug", description: "", shortDescription: nil),
        ControlDeckSkill(name: "describe", path: "/skills/describe", description: "", shortDescription: nil),
        ControlDeckSkill(name: "devops", path: "/skills/devops", description: "", shortDescription: nil),
        ControlDeckSkill(name: "dedupe", path: "/skills/dedupe", description: "", shortDescription: nil),
        ControlDeckSkill(name: "delta", path: "/skills/delta", description: "", shortDescription: nil),
        ControlDeckSkill(name: "debrief", path: "/skills/debrief", description: "", shortDescription: nil),
        ControlDeckSkill(name: "decrypt", path: "/skills/decrypt", description: "", shortDescription: nil),
        ControlDeckSkill(name: "declutter", path: "/skills/declutter", description: "", shortDescription: nil),
        ControlDeckSkill(name: "decompose", path: "/skills/decompose", description: "", shortDescription: nil),
        ControlDeckSkill(name: "defer", path: "/skills/defer", description: "", shortDescription: nil),
        ControlDeckSkill(name: "defend", path: "/skills/defend", description: "", shortDescription: nil),
        ControlDeckSkill(name: "delight", path: "/skills/delight", description: "", shortDescription: nil),
      ]
    )

    #expect(suggestions.count == ControlDeckAutocompletePlanner.maxSuggestionCount)
    #expect(suggestions.allSatisfy { $0.kind == .skill })
  }
}
