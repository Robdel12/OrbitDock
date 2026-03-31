@testable import OrbitDock
import Testing

struct ControlDeckTextEditingTests {
  @Test func trailingSkillQueryReadsTokenAtEnd() {
    let query = ControlDeckTextEditing.trailingTokenQuery(in: "Use $des", prefix: "$")
    #expect(query == "des")
  }

  @Test func trailingMentionQueryRequiresWhitespaceBoundary() {
    let invalid = ControlDeckTextEditing.trailingTokenQuery(
      in: "email@domain.com",
      prefix: "@",
      requireWhitespaceBoundaryBeforePrefix: true
    )
    #expect(invalid == nil)

    let valid = ControlDeckTextEditing.trailingTokenQuery(
      in: "review @Server",
      prefix: "@",
      requireWhitespaceBoundaryBeforePrefix: true
    )
    #expect(valid == "Server")
  }

  @Test func replacingTrailingSkillTokenReplacesInPlace() {
    let updated = ControlDeckTextEditing.replacingTrailingToken(
      in: "Ship this $de",
      prefix: "$",
      with: "$deploy "
    )
    #expect(updated == "Ship this $deploy ")
  }

  @Test func inlineSkillNamesReturnsKnownNamesInAppearanceOrder() {
    let names = ControlDeckTextEditing.inlineSkillNames(
      in: "Use $build, then $unknown, then $ship and $BUILD again.",
      availableSkillNames: ["build", "ship"]
    )
    #expect(names == ["build", "ship"])
  }
}
