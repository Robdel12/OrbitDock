@testable import OrbitDock
import Testing

@MainActor
struct ApprovalCardModelTests {

  @Test func modeResolverTreatsFallbackQuestionAsQuestionMode() {
    let session = makeDirectSession(attentionReason: .awaitingReply, pendingApprovalId: nil)

    let mode = ApprovalCardModeResolver.resolve(
      for: session,
      pendingApprovalId: "req-question",
      approvalType: .question
    )

    #expect(mode == .question)
  }

  @Test func modeResolverTreatsFallbackExecAsPermissionMode() {
    let session = makeDirectSession(attentionReason: .awaitingPermission, pendingApprovalId: nil)

    let mode = ApprovalCardModeResolver.resolve(
      for: session,
      pendingApprovalId: "req-exec",
      approvalType: .exec
    )

    #expect(mode == .permission)
  }

  @Test func builderUsesPendingApprovalHistoryWhenRequestIdIsMissingOnSession() {
    let sessionId = "session-approval-history"
    let session = makeDirectSession(
      id: sessionId,
      attentionReason: .awaitingPermission,
      pendingApprovalId: nil
    )

    let state = ServerAppState()
    state.session(sessionId).approvalHistory = [
      ServerApprovalHistoryItem(
        id: 42,
        sessionId: sessionId,
        requestId: "req-from-history",
        approvalType: .exec,
        toolName: "Bash",
        command: "git status",
        filePath: nil,
        cwd: "/tmp",
        decision: nil,
        proposedAmendment: nil,
        createdAt: "2026-02-23T00:00:00Z",
        decidedAt: nil
      )
    ]

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: nil,
      serverState: state
    )

    #expect(model != nil)
    #expect(model?.approvalId == "req-from-history")
    #expect(model?.approvalType == .exec)
    #expect(model?.toolName == "Bash")
    #expect(model?.command == "git status")
    #expect(model?.mode == .permission)
  }

  @Test func builderNormalizesShellWrapperWhenUsingPendingApprovalCommandFallback() {
    let session = makeDirectSession(
      id: "session-command-fallback",
      attentionReason: .awaitingPermission,
      pendingApprovalId: "req-zsh"
    )

    let pendingApproval = ServerApprovalRequest(
      id: "req-zsh",
      sessionId: session.id,
      type: .exec,
      toolName: "Bash",
      toolInput: nil,
      command: "/bin/zsh -lc xcodebuild -project OrbitDock.xcodeproj -scheme OrbitDock -showdestinations",
      filePath: nil,
      diff: nil,
      question: nil,
      proposedAmendment: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval,
      serverState: ServerAppState()
    )

    #expect(model?.mode == .permission)
    #expect(model?.command == "xcodebuild -project OrbitDock.xcodeproj -scheme OrbitDock -showdestinations")
  }

  @Test func builderParsesQuestionOptionsFromPendingToolInput() {
    let toolInput = """
    {
      "questions": [
        {
          "id": "speed",
          "header": "Speed",
          "question": "How do you want to launch?",
          "options": [
            { "label": "Open Sheet", "description": "Open full sheet first" },
            { "label": "Quick Launch", "description": "Use defaults immediately" }
          ]
        }
      ]
    }
    """

    let session = Session(
      id: "session-question-options",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingQuestion,
      pendingToolInput: toolInput,
      provider: .claude,
      claudeIntegrationMode: .direct,
      pendingApprovalId: "req-question"
    )

    let state = ServerAppState()
    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: nil,
      serverState: state
    )

    #expect(model?.mode == .question)
    #expect(model?.questionId == "speed")
    #expect(model?.question == "How do you want to launch?")
    #expect(model?.questionOptions.count == 2)
    #expect(model?.questionOptions.first?.label == "Open Sheet")
  }

  @Test func builderParsesMultipleQuestionPromptsFromPendingToolInput() {
    let toolInput = """
    {
      "questions": [
        {
          "id": "speed",
          "header": "Speed",
          "question": "How do you want to launch?",
          "options": [
            { "label": "Open Sheet", "description": "Open full sheet first" },
            { "label": "Quick Launch", "description": "Use defaults immediately" }
          ]
        },
        {
          "id": "confirm",
          "header": "Confirm",
          "question": "Apply this setup?",
          "multiSelect": true,
          "isOther": true,
          "isSecret": false
        }
      ]
    }
    """

    let session = Session(
      id: "session-multi-question-options",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingQuestion,
      pendingToolInput: toolInput,
      provider: .claude,
      claudeIntegrationMode: .direct,
      pendingApprovalId: "req-question"
    )

    let state = ServerAppState()
    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: nil,
      serverState: state
    )

    #expect(model?.mode == .question)
    #expect(model?.questions.count == 2)
    #expect(model?.questions.first?.id == "speed")
    #expect(model?.questions.first?.options.count == 2)
    #expect(model?.questions.last?.id == "confirm")
    #expect(model?.questions.last?.allowsMultipleSelection == true)
    #expect(model?.questions.last?.allowsOther == true)
    #expect(model?.questions.last?.isSecret == false)
  }

  private func makeDirectSession(
    id: String = "session-1",
    attentionReason: Session.AttentionReason,
    pendingApprovalId: String?
  ) -> Session {
    Session(
      id: id,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: attentionReason,
      provider: .codex,
      codexIntegrationMode: .direct,
      pendingApprovalId: pendingApprovalId
    )
  }
}
