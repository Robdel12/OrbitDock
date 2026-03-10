import Foundation
@testable import OrbitDock
import Testing

struct DirectSessionComposerPendingPlannerTests {
  @Test func toggledAnswersSupportsSingleAndMultiSelect() {
    let single = DirectSessionComposerPendingPlanner.toggledAnswers(
      existingAnswers: ["q1": ["A"]],
      questionId: "q1",
      optionLabel: "B",
      allowsMultipleSelection: false
    )
    #expect(single["q1"] == ["B"])

    let multiSelected = DirectSessionComposerPendingPlanner.toggledAnswers(
      existingAnswers: ["q1": ["A"]],
      questionId: "q1",
      optionLabel: "B",
      allowsMultipleSelection: true
    )
    #expect(multiSelected["q1"] == ["A", "B"])

    let multiDeselected = DirectSessionComposerPendingPlanner.toggledAnswers(
      existingAnswers: multiSelected,
      questionId: "q1",
      optionLabel: "A",
      allowsMultipleSelection: true
    )
    #expect(multiDeselected["q1"] == ["B"])
  }

  @Test func promptAnsweringAndCollectionPreferConcreteResponses() {
    let promptA = ApprovalQuestionPrompt(
      id: "q1",
      header: "Question 1",
      question: "Choose one",
      options: [ApprovalQuestionOption(label: "A", description: nil)],
      allowsMultipleSelection: false,
      allowsOther: true,
      isSecret: false
    )
    let promptB = ApprovalQuestionPrompt(
      id: "q2",
      header: "Question 2",
      question: "Tell me more",
      options: [],
      allowsMultipleSelection: false,
      allowsOther: true,
      isSecret: false
    )

    let answers = ["q1": ["A"]]
    let drafts = ["q2": " custom note "]

    #expect(
      DirectSessionComposerPendingPlanner.promptIsAnswered(
        prompt: promptA,
        answers: answers,
        drafts: drafts
      )
    )
    #expect(
      DirectSessionComposerPendingPlanner.promptIsAnswered(
        prompt: promptB,
        answers: answers,
        drafts: drafts
      )
    )
    #expect(
      DirectSessionComposerPendingPlanner.allPromptsAnswered(
        prompts: [promptA, promptB],
        answers: answers,
        drafts: drafts
      )
    )

    let collected = DirectSessionComposerPendingPlanner.collectedAnswers(
      prompts: [promptA, promptB],
      answers: answers,
      drafts: drafts
    )
    #expect(collected["q1"] == ["A"])
    #expect(collected["q2"] == ["custom note"])
  }

  @Test func primaryAnswerPrefersFirstPromptAnswerThenFallsBack() {
    let promptA = ApprovalQuestionPrompt(
      id: "q1",
      header: nil,
      question: "First",
      options: [],
      allowsMultipleSelection: false,
      allowsOther: true,
      isSecret: false
    )
    let promptB = ApprovalQuestionPrompt(
      id: "q2",
      header: nil,
      question: "Second",
      options: [],
      allowsMultipleSelection: false,
      allowsOther: true,
      isSecret: false
    )

    let first = DirectSessionComposerPendingPlanner.primaryAnswer(
      prompts: [promptA, promptB],
      answers: ["q1": ["alpha"], "q2": ["beta"]]
    )
    #expect(first.questionId == "q1")
    #expect(first.answer == "alpha")

    let fallback = DirectSessionComposerPendingPlanner.primaryAnswer(
      prompts: [promptA, promptB],
      answers: ["q2": ["beta"]]
    )
    #expect(fallback.questionId == "q1")
    #expect(fallback.answer == "beta")
  }

  @Test func pendingStateResetClearsPerRequestInputs() {
    var state = DirectSessionComposerPendingState()
    state.isExpanded = false
    state.promptIndex = 2
    state.answers = ["q1": ["A"]]
    state.drafts = ["q2": "draft"]
    state.showsDenyReason = true
    state.denyReason = "Nope"
    state.measuredContentHeight = 120
    state.lastHapticApprovalIdentity = "keep-me"

    state.resetForNewRequest()

    #expect(state.isExpanded)
    #expect(state.promptIndex == 0)
    #expect(state.answers.isEmpty)
    #expect(state.drafts.isEmpty)
    #expect(state.showsDenyReason == false)
    #expect(state.denyReason.isEmpty)
    #expect(state.measuredContentHeight == 0)
    #expect(state.lastHapticApprovalIdentity == "keep-me")
  }
}
