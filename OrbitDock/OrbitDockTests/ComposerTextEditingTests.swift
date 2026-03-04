@testable import OrbitDock
import Testing

struct ComposerTextEditingTests {
  @Test func applySkillCompletionReplacesTrailingSkillToken() {
    let updated = ComposerTextEditing.applySkillCompletion(in: "Ship this $de", skillName: "deploy")
    #expect(updated == "Ship this $deploy ")
  }

  @Test func applySkillCompletionReturnsNilWithoutSkillToken() {
    let updated = ComposerTextEditing.applySkillCompletion(in: "Ship this", skillName: "deploy")
    #expect(updated == nil)
  }

  @Test func applyMentionCompletionReplacesTrailingMentionToken() {
    let updated = ComposerTextEditing.applyMentionCompletion(in: "Review @Serv", fileName: "ServerManager.swift")
    #expect(updated == "Review @ServerManager.swift ")
  }

  @Test func applyMentionCompletionReturnsNilWithoutMentionToken() {
    let updated = ComposerTextEditing.applyMentionCompletion(in: "Review file", fileName: "ServerManager.swift")
    #expect(updated == nil)
  }

  @Test func activateCommandDeckTokenAppendsWithSpacerWhenNeeded() {
    let updated = ComposerTextEditing.activateCommandDeckToken(in: "run tests", prefill: nil)
    #expect(updated == "run tests /")
  }

  @Test func activateCommandDeckTokenReplacesExistingTrailingToken() {
    let updated = ComposerTextEditing.activateCommandDeckToken(in: "run /mc", prefill: "mcp")
    #expect(updated == "run /mcp")
  }

  @Test func removingTrailingCommandDeckTokenStripsToken() {
    let updated = ComposerTextEditing.removingTrailingCommandDeckToken(in: "run /mcp")
    #expect(updated == "run")
  }

  @Test func removingTrailingCommandDeckTokenIgnoresSlashInsideSentence() {
    let updated = ComposerTextEditing.removingTrailingCommandDeckToken(in: "run /mcp now")
    #expect(updated == nil)
  }

  @Test func replacingTrailingCommandDeckTokenReplacesTokenInPlace() {
    let updated = ComposerTextEditing.replacingTrailingCommandDeckToken(
      in: "run /mc",
      replacement: "$deploy",
      appendSpace: true
    )
    #expect(updated == "run $deploy ")
  }

  @Test func replacingTrailingCommandDeckTokenAppendsWhenNoToken() {
    let updated = ComposerTextEditing.replacingTrailingCommandDeckToken(
      in: "run tests",
      replacement: "@ServerManager.swift",
      appendSpace: false
    )
    #expect(updated == "run tests @ServerManager.swift")
  }
}
