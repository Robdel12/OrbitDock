import Foundation
@testable import OrbitDock
import Testing

struct ServerAppStateApprovalQueueTests {
  @MainActor
  @Test func approvalRequestedDoesNotOverrideActiveQueueHead() {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-approval-request-order"

    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-1",
      sessionId: sessionId,
      type: .exec
    )

    state.connection.onApprovalRequested?(
      sessionId,
      makeApprovalRequest(id: "req-2", sessionId: sessionId, type: .exec)
    )

    #expect(state.session(sessionId).pendingApproval?.id == "req-1")
    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == "req-1")
  }

  @MainActor
  @Test func approveToolUsesSessionListPendingApprovalAsSourceOfTruth() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-summary-head"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-head")
    ])
    await Task.yield()
    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-observable-drift",
      sessionId: sessionId,
      type: .exec
    )

    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == "req-head")

    let result = state.approveTool(
      sessionId: sessionId,
      requestId: "req-observable-drift",
      decision: "approved"
    )

    switch result {
      case let .stale(nextPendingRequestId):
        #expect(nextPendingRequestId == "req-head")
      case .dispatched:
        Issue.record("Expected stale result when request ID is not the server-declared queue head.")
    }
  }

  @MainActor
  @Test func approveToolLeavesPendingApprovalServerAuthoritative() {
    let state = ServerAppState()
    let sessionId = "session-approval-queue"

    let first = makeApprovalRequest(id: "req-1", sessionId: sessionId, type: .exec)
    state.session(sessionId).pendingApproval = first
    state.session(sessionId).approvalHistory = [
      makeApprovalHistoryItem(id: 1, requestId: "req-1", sessionId: sessionId),
      makeApprovalHistoryItem(id: 2, requestId: "req-2", sessionId: sessionId),
    ]

    let result = state.approveTool(sessionId: sessionId, requestId: "req-1", decision: "approved")

    switch result {
      case .dispatched:
        #expect(true)
      case .stale:
        Issue.record("Expected approval dispatch to succeed.")
    }
    #expect(state.session(sessionId).pendingApproval?.id == "req-1")
    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == "req-1")
  }

  @MainActor
  @Test func approvalsListClearsPendingStateImmediatelyAfterResolution() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-approval-resolve"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-1")
    ])
    await Task.yield()

    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-1",
      sessionId: sessionId,
      type: .exec
    )

    state.connection.onApprovalsList?(
      sessionId,
      [
        ServerApprovalHistoryItem(
          id: 1,
          sessionId: sessionId,
          requestId: "req-1",
          approvalType: .exec,
          toolName: "Bash",
          command: "echo test",
          filePath: nil,
          cwd: nil,
          decision: "approved",
          proposedAmendment: nil,
          createdAt: "2026-02-24T00:00:00Z",
          decidedAt: "2026-02-24T00:00:01Z"
        )
      ]
    )
    await Task.yield()
    await Task.yield()

    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == nil)
    #expect(state.session(sessionId).pendingApproval == nil)
    #expect(state.sessions.first(where: { $0.id == sessionId })?.pendingApprovalId == nil)
    #expect(state.sessions.first(where: { $0.id == sessionId })?.attentionReason == Session.AttentionReason.none)
  }

  @MainActor
  @Test func approvalsListPromotesOldestUnresolvedRequestAsQueueHead() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-approval-queue-head"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-2")
    ])
    await Task.yield()

    state.connection.onApprovalsList?(
      sessionId,
      [
        makeApprovalHistoryItem(id: 2, requestId: "req-2", sessionId: sessionId),
        makeApprovalHistoryItem(id: 1, requestId: "req-1", sessionId: sessionId),
      ]
    )
    await Task.yield()

    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == "req-1")
    #expect(state.sessions.first(where: { $0.id == sessionId })?.pendingApprovalId == "req-1")
  }

  @MainActor
  @Test func approveToolReturnsStaleWithNextPendingRequestId() {
    let state = ServerAppState()
    let sessionId = "session-approval-stale"

    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-current",
      sessionId: sessionId,
      type: .exec
    )

    let result = state.approveTool(sessionId: sessionId, requestId: "req-old", decision: "approved")

    switch result {
      case let .stale(nextPendingRequestId):
        #expect(nextPendingRequestId == "req-current")
      case .dispatched:
        Issue.record("Expected stale approval result for unknown request ID.")
    }
  }

  @MainActor
  @Test func answerQuestionLeavesPendingApprovalServerAuthoritative() {
    let state = ServerAppState()
    let sessionId = "session-question-approval"

    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-question",
      sessionId: sessionId,
      type: .question
    )

    let result = state.answerQuestion(
      sessionId: sessionId,
      requestId: "req-question",
      answer: "Ship it"
    )

    switch result {
      case .dispatched:
        #expect(true)
      case .stale:
        Issue.record("Expected answer dispatch to succeed.")
    }

    #expect(state.session(sessionId).pendingApproval?.id == "req-question")
    #expect(state.pendingApprovalType(sessionId: sessionId) == .question)
  }

  private func makeApprovalRequest(id: String, sessionId: String, type: ServerApprovalType) -> ServerApprovalRequest {
    ServerApprovalRequest(
      id: id,
      sessionId: sessionId,
      type: type,
      toolName: "Bash",
      toolInput: #"{"command":"echo test"}"#,
      command: "echo test",
      filePath: nil,
      diff: nil,
      question: nil,
      preview: nil,
      proposedAmendment: nil
    )
  }

  private func makeApprovalHistoryItem(id: Int64, requestId: String, sessionId: String) -> ServerApprovalHistoryItem {
    ServerApprovalHistoryItem(
      id: id,
      sessionId: sessionId,
      requestId: requestId,
      approvalType: .exec,
      toolName: "Bash",
      command: "echo test",
      filePath: nil,
      cwd: nil,
      decision: nil,
      proposedAmendment: nil,
      createdAt: "2026-02-24T00:00:00Z",
      decidedAt: nil
    )
  }

  private func makeSessionSummary(id: String, pendingApprovalId: String?) -> ServerSessionSummary {
    ServerSessionSummary(
      id: id,
      provider: .codex,
      projectPath: "/tmp/project",
      transcriptPath: nil,
      projectName: nil,
      model: nil,
      customName: nil,
      summary: nil,
      status: .active,
      workStatus: pendingApprovalId == nil ? .working : .permission,
      tokenUsage: nil,
      tokenUsageSnapshotKind: nil,
      hasPendingApproval: pendingApprovalId != nil,
      codexIntegrationMode: nil,
      claudeIntegrationMode: nil,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: nil,
      pendingToolName: pendingApprovalId == nil ? nil : "Bash",
      pendingToolInput: pendingApprovalId == nil ? nil : #"{"command":"echo test"}"#,
      pendingQuestion: nil,
      pendingApprovalId: pendingApprovalId,
      startedAt: "2026-02-24T00:00:00Z",
      lastActivityAt: "2026-02-24T00:00:00Z",
      gitBranch: nil,
      gitSha: nil,
      currentCwd: nil,
      firstPrompt: nil,
      lastMessage: nil,
      effort: nil
    )
  }
}
