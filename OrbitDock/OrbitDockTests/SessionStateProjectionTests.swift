import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionStateProjectionTests {
  @Test func sessionApplyPendingApprovalSummarySetsPermissionFieldsFromServerRequest() {
    var session = Session(
      id: "session-1",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .none,
      provider: .codex,
      codexIntegrationMode: .direct
    )

    session.applyPendingApprovalSummary(execApprovalRequest())

    #expect(session.pendingApprovalId == "req-1")
    #expect(session.pendingToolName == "Bash")
    #expect(session.pendingToolInput == #"{"command":"git status"}"#)
    #expect(session.pendingPermissionDetail == "git status")
    #expect(session.pendingQuestion == nil)
    #expect(session.attentionReason == .awaitingPermission)
    #expect(session.workStatus == .permission)
  }

  @Test func sessionClearPendingApprovalSummaryClearsFieldsAndResetsAttentionWhenRequested() {
    var session = Session(
      id: "session-1",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingQuestion,
      pendingToolName: "AskUserQuestion",
      pendingPermissionDetail: "Need input",
      pendingQuestion: "Ship it?",
      provider: .codex,
      codexIntegrationMode: .direct,
      pendingApprovalId: "req-q"
    )

    session.clearPendingApprovalSummary(resetAttention: true)

    #expect(session.pendingApprovalId == nil)
    #expect(session.pendingToolName == nil)
    #expect(session.pendingPermissionDetail == nil)
    #expect(session.pendingQuestion == nil)
    #expect(session.attentionReason == .none)
    #expect(session.workStatus == .working)
  }

  @Test func sessionObservableApplySessionMirrorsListSummaryFields() {
    let observable = SessionObservable(id: "session-1")
    let session = Session(
      id: "session-1",
      endpointId: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
      endpointName: "Primary",
      projectPath: "/tmp/project",
      projectName: "project",
      branch: "main",
      model: "gpt-5",
      summary: "Refactor session store",
      customName: "Important Session",
      firstPrompt: "Please refactor this",
      transcriptPath: "/tmp/transcript.jsonl",
      status: .active,
      workStatus: .waiting,
      startedAt: Date(timeIntervalSince1970: 100),
      totalTokens: 321,
      lastActivityAt: Date(timeIntervalSince1970: 200),
      attentionReason: .awaitingReply,
      pendingToolName: "Bash",
      pendingToolInput: #"{"command":"pwd"}"#,
      pendingPermissionDetail: "pwd",
      pendingQuestion: "Continue?",
      provider: .claude,
      claudeIntegrationMode: .direct,
      pendingApprovalId: "req-42",
      inputTokens: 120,
      outputTokens: 201,
      cachedTokens: 12,
      contextWindow: 200_000
    )

    observable.applySession(session)

    #expect(observable.endpointName == "Primary")
    #expect(observable.projectPath == "/tmp/project")
    #expect(observable.branch == "main")
    #expect(observable.summary == "Refactor session store")
    #expect(observable.customName == "Important Session")
    #expect(observable.status == .active)
    #expect(observable.workStatus == .waiting)
    #expect(observable.attentionReason == .awaitingReply)
    #expect(observable.pendingApprovalId == "req-42")
    #expect(observable.pendingPermissionDetail == "pwd")
    #expect(observable.provider == .claude)
    #expect(observable.claudeIntegrationMode == .direct)
    #expect(observable.totalTokens == 321)
    #expect(observable.contextWindow == 200_000)
  }

  @Test func sessionObservableApprovalProjectionUsesQuestionTextAndClearsWithoutResettingAttentionByDefault() {
    let observable = SessionObservable(id: "session-1")
    let request = questionApprovalRequest()

    observable.applyPendingApproval(request)

    #expect(observable.pendingApproval?.id == "req-q")
    #expect(observable.pendingApprovalId == "req-q")
    #expect(observable.pendingToolName == "AskUserQuestion")
    #expect(observable.pendingQuestion == "Ship it?")
    #expect(observable.attentionReason == .awaitingQuestion)
    #expect(observable.workStatus == .permission)

    observable.clearPendingApprovalDetails(resetAttention: false)

    #expect(observable.pendingApproval == nil)
    #expect(observable.pendingApprovalId == nil)
    #expect(observable.pendingToolName == nil)
    #expect(observable.pendingQuestion == nil)
    #expect(observable.attentionReason == .awaitingQuestion)
    #expect(observable.workStatus == .permission)
  }

  @Test func sessionObservableTrimInactiveDetailPayloadsClearsHeavyNonConversationState() {
    let observable = SessionObservable(id: "session-1")
    observable.turnDiffs = [ServerTurnDiff(turnId: "turn-1", diff: "diff")]
    observable.diff = "working tree diff"
    observable.plan = "[]"
    observable.currentTurnId = "turn-1"
    observable.reviewComments = [
      ServerReviewComment(
        id: "comment-1",
        sessionId: "session-1",
        turnId: nil,
        filePath: "/tmp/file.swift",
        lineStart: 12,
        lineEnd: nil,
        body: "Please fix",
        tag: nil,
        status: .open,
        createdAt: "2026-03-09T10:00:00Z",
        updatedAt: nil
      )
    ]
    observable.pendingShellContext = [
      ShellContextEntry(command: "pwd", output: "/tmp/project", exitCode: 0, timestamp: Date())
    ]

    observable.trimInactiveDetailPayloads()

    #expect(observable.turnDiffs.isEmpty)
    #expect(observable.diff == nil)
    #expect(observable.plan == nil)
    #expect(observable.currentTurnId == nil)
    #expect(observable.reviewComments.isEmpty)
    #expect(observable.pendingShellContext.isEmpty)
  }

  private func execApprovalRequest() -> ServerApprovalRequest {
    ServerApprovalRequest(
      id: "req-1",
      sessionId: "session-1",
      type: .exec,
      toolName: "Bash",
      toolInput: #"{"command":"git status"}"#,
      command: "git status",
      preview: ServerApprovalPreview(
        type: .shellCommand,
        value: "git status",
        compact: "git status"
      )
    )
  }

  private func questionApprovalRequest() -> ServerApprovalRequest {
    ServerApprovalRequest(
      id: "req-q",
      sessionId: "session-1",
      type: .question,
      toolName: "AskUserQuestion",
      question: "Fallback question",
      questionPrompts: [
        ServerApprovalQuestionPrompt(
          id: "q1",
          header: "Question",
          question: "Ship it?"
        )
      ]
    )
  }
}
