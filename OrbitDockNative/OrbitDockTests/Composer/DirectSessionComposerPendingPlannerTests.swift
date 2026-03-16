import Foundation
@testable import OrbitDock
import Testing

@MainActor
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
    state.permissionGrantScope = .session
    state.answers = ["q1": ["A"]]
    state.drafts = ["q2": "draft"]
    state.showsDenyReason = true
    state.denyReason = "Nope"
    state.measuredContentHeight = 120
    state.lastHapticApprovalIdentity = "keep-me"

    state.resetForNewRequest()

    #expect(state.isExpanded)
    #expect(state.promptIndex == 0)
    #expect(state.permissionGrantScope == .turn)
    #expect(state.answers.isEmpty)
    #expect(state.drafts.isEmpty)
    #expect(state.showsDenyReason == false)
    #expect(state.denyReason.isEmpty)
    #expect(state.measuredContentHeight == 0)
    #expect(state.lastHapticApprovalIdentity == "keep-me")
  }

  @Test func questionFooterStateBoundsIndexAndLocksSubmitUntilAnswersExist() {
    let first = ApprovalQuestionPrompt(
      id: "q1",
      header: nil,
      question: "First",
      options: [ApprovalQuestionOption(label: "A", description: nil)],
      allowsMultipleSelection: false,
      allowsOther: false,
      isSecret: false
    )
    let second = ApprovalQuestionPrompt(
      id: "q2",
      header: nil,
      question: "Second",
      options: [],
      allowsMultipleSelection: false,
      allowsOther: true,
      isSecret: false
    )

    let initial = DirectSessionComposerPendingPlanner.questionFooterState(
      prompts: [first, second],
      promptIndex: 99,
      answers: ["q1": ["A"]],
      drafts: [:]
    )
    #expect(initial.activeIndex == 1)
    #expect(initial.submitDisabled)

    let ready = DirectSessionComposerPendingPlanner.questionFooterState(
      prompts: [first, second],
      promptIndex: 99,
      answers: ["q1": ["A"]],
      drafts: ["q2": "done"]
    )
    #expect(ready.activeIndex == 1)
    #expect(ready.submitDisabled == false)
  }

  @Test func presentationBuildsShellCommandFallbackAndPromptCount() {
    let model = ApprovalCardModel(
      mode: .question,
      toolName: "Bash",
      previewType: .shellCommand,
      shellSegments: [],
      serverManifest: nil,
      decisionScope: nil,
      command: "echo hi",
      filePath: nil,
      risk: .normal,
      riskFindings: [],
      diff: nil,
      questions: [
        ApprovalQuestionPrompt(
          id: "q1",
          header: nil,
          question: "First",
          options: [],
          allowsMultipleSelection: false,
          allowsOther: true,
          isSecret: false
        ),
        ApprovalQuestionPrompt(
          id: "q2",
          header: nil,
          question: "Second",
          options: [],
          allowsMultipleSelection: false,
          allowsOther: true,
          isSecret: false
        ),
      ],
      permissionRequest: nil,
      hasAmendment: false,
      amendmentDetail: nil,
      approvalType: .question,
      projectPath: "/tmp/OrbitDock",
      approvalId: "approval-1",
      sessionId: "session-1",
      elicitationMode: nil,
      elicitationSchema: nil,
      elicitationUrl: nil,
      elicitationMessage: nil,
      mcpServerName: nil,
      networkHost: nil,
      networkProtocol: nil
    )

    let presentation = DirectSessionComposerPendingPlanner.presentation(
      for: model,
      showsDenyReason: false,
      measuredHeight: 0,
      maxHeight: 220
    )

    #expect(presentation.title == "Question")
    #expect(presentation.statusText == "QUESTION")
    #expect(presentation.promptCountText == "2 prompts")
    #expect(presentation.commandChainSegments.map(\.command) == ["echo hi"])
    #expect(presentation.clampedContentHeight == 152)
  }

  @Test func permissionsPresentationUsesPermissionsTitleAndStatus() {
    let model = ApprovalCardModel(
      mode: .permission,
      toolName: "Permissions",
      previewType: .action,
      shellSegments: [],
      serverManifest: nil,
      decisionScope: nil,
      command: nil,
      filePath: nil,
      risk: .normal,
      riskFindings: [],
      diff: nil,
      questions: [],
      permissionRequest: ApprovalPermissionRequest(
        reason: "Needs broader access.",
        groups: [
          ApprovalPermissionGroup(title: "Network", iconName: "network", lines: ["Allow outbound access."]),
        ]
      ),
      hasAmendment: false,
      amendmentDetail: nil,
      approvalType: .permissions,
      projectPath: "/tmp/OrbitDock",
      approvalId: "approval-permissions",
      sessionId: "session-permissions",
      elicitationMode: nil,
      elicitationSchema: nil,
      elicitationUrl: nil,
      elicitationMessage: nil,
      mcpServerName: nil,
      networkHost: nil,
      networkProtocol: nil
    )

    let presentation = DirectSessionComposerPendingPlanner.presentation(
      for: model,
      showsDenyReason: false,
      measuredHeight: 0,
      maxHeight: 260
    )

    #expect(presentation.title == "Permissions Request")
    #expect(presentation.statusText == "PERMISSIONS")
    #expect(presentation.fallbackHeight == 164)
  }

  @Test func questionContentStateBoundsActiveIndex() {
    let prompts = [
      ApprovalQuestionPrompt(
        id: "q1",
        header: nil,
        question: "First",
        options: [],
        allowsMultipleSelection: false,
        allowsOther: true,
        isSecret: false
      ),
      ApprovalQuestionPrompt(
        id: "q2",
        header: nil,
        question: "Second",
        options: [],
        allowsMultipleSelection: false,
        allowsOther: true,
        isSecret: false
      ),
    ]

    let state = DirectSessionComposerPendingPlanner.questionContentState(
      prompts: prompts,
      promptIndex: 99
    )

    #expect(state.activeIndex == 1)
    #expect(state.activePrompt?.id == "q2")
  }

  @Test func permissionFooterStateTracksDenyComposerAndOverflow() {
    let denyActions = [
      ApprovalCardConfiguration.MenuAction(title: "Deny", decision: "denied"),
      ApprovalCardConfiguration.MenuAction(title: "Deny with Reason", decision: "deny_reason"),
    ]
    let approveActions = [
      ApprovalCardConfiguration.MenuAction(title: "Approve Once", decision: "approved"),
      ApprovalCardConfiguration.MenuAction(title: "Approve Always", decision: "approved_always"),
    ]

    let composingDeny = DirectSessionComposerPendingPlanner.permissionFooterState(
      denyActions: denyActions,
      approveActions: approveActions,
      showsDenyReason: true,
      hasDenyReason: false
    )
    #expect(composingDeny.showsDenyReason)
    #expect(composingDeny.denySubmitDisabled)
    #expect(composingDeny.hasOverflowActions)

    let normal = DirectSessionComposerPendingPlanner.permissionFooterState(
      denyActions: denyActions,
      approveActions: approveActions,
      showsDenyReason: false,
      hasDenyReason: true
    )
    #expect(normal.showsDenyReason == false)
    #expect(normal.denySubmitDisabled == false)
    #expect(normal.primaryDenyAction?.decision == "denied")
    #expect(normal.primaryApproveAction?.decision == "approved")
  }

  @Test func hapticForDecisionMapsApprovalOutcomesDeterministically() {
    #expect(DirectSessionComposerPendingPlanner.hapticForDecision("approved") == .success)
    #expect(DirectSessionComposerPendingPlanner.hapticForDecision("approved_always") == .success)
    #expect(DirectSessionComposerPendingPlanner.hapticForDecision("abort") == .destructive)
    #expect(DirectSessionComposerPendingPlanner.hapticForDecision("denied") == .warning)
  }
}
