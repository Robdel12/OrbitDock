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
