@testable import OrbitDock
import Testing

struct DirectSessionComposerInputStateTests {
  @Test func skillCompletionActivatesAndRequestsLoadWhenSkillsAreMissing() {
    var state = DirectSessionComposerInputState()

    let needsLoad = state.updateSkillCompletion(for: "Ship this $dep", availableSkillNames: [])

    #expect(needsLoad)
    #expect(state.skillCompletion.isActive)
    #expect(state.skillCompletion.query == "dep")
    #expect(state.skillCompletion.index == 0)
  }

  @Test func skillCompletionDismissesWhenExactSkillAlreadyExists() {
    var state = DirectSessionComposerInputState()
    state.skillCompletion.activate(query: "old")

    let needsLoad = state.updateSkillCompletion(
      for: "Ship this $deploy",
      availableSkillNames: ["deploy", "review"]
    )

    #expect(!needsLoad)
    #expect(!state.skillCompletion.isActive)
    #expect(state.skillCompletion.query.isEmpty)
  }

  @Test func mentionCompletionRequiresWhitespaceBeforeAtSymbol() {
    var state = DirectSessionComposerInputState()

    let shouldLoad = state.updateMentionCompletion(
      for: "email@test",
      attachedMentions: []
    )

    #expect(!shouldLoad)
    #expect(!state.mentionCompletion.isActive)
  }

  @Test func mentionCompletionActivatesForTrailingMentionToken() {
    var state = DirectSessionComposerInputState()

    let shouldLoad = state.updateMentionCompletion(
      for: "Review @Serv",
      attachedMentions: []
    )

    #expect(shouldLoad)
    #expect(state.mentionCompletion.isActive)
    #expect(state.mentionCompletion.query == "Serv")
  }

  @Test func commandDeckCompletionReturnsExpectedLoadHints() {
    var state = DirectSessionComposerInputState()

    let requests = state.updateCommandDeckCompletion(
      for: "run /mcp",
      hasSkillsPanel: true,
      availableSkillsAreLoaded: false,
      hasMcpTools: false
    )

    #expect(state.commandDeck.isActive)
    #expect(state.commandDeck.query == "mcp")
    #expect(requests.contains(.projectFiles))
    #expect(requests.contains(.skills))
    #expect(requests.contains(.mcpTools))
  }

  @Test func commandDeckDismissesWhenTokenContainsWhitespace() {
    var state = DirectSessionComposerInputState()
    state.commandDeck.activate(query: "old")

    let requests = state.updateCommandDeckCompletion(
      for: "run /mcp now",
      hasSkillsPanel: false,
      availableSkillsAreLoaded: true,
      hasMcpTools: true
    )

    #expect(requests.isEmpty)
    #expect(!state.commandDeck.isActive)
    #expect(state.commandDeck.query == "old")
  }

  @Test func selectionStateMovesWithinBounds() {
    var state = ComposerSelectionState(isActive: true, query: "q", index: 0)

    let movedUp = state.move(.upArrow, itemCount: 3)
    #expect(movedUp)
    #expect(state.index == 0)
    let movedDown = state.move(.downArrow, itemCount: 3)
    #expect(movedDown)
    #expect(state.index == 1)
    let movedControlN = state.move(.controlN, itemCount: 3)
    #expect(movedControlN)
    #expect(state.index == 2)
    let movedControlP = state.move(.controlP, itemCount: 3)
    #expect(movedControlP)
    #expect(state.index == 1)
  }

  @Test func focusStateRequestsRefocusOnlyForProgrammaticBlurOnActiveSession() {
    var focus = ComposerFocusState()
    focus.requestFocus()

    let shouldRefocus = focus.handle(.ended(userInitiated: false), isSessionActive: true)

    #expect(shouldRefocus)
    #expect(!focus.isFocused)
    #expect(focus.shouldMaintainTypingFocus)
  }

  @Test func focusStateStopsMaintainingFocusAfterUserBlur() {
    var focus = ComposerFocusState()
    focus.requestFocus()

    let shouldRefocus = focus.handle(.ended(userInitiated: true), isSessionActive: true)

    #expect(!shouldRefocus)
    #expect(!focus.shouldMaintainTypingFocus)
  }
}
