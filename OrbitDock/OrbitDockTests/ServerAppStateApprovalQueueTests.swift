import Foundation
@testable import OrbitDock
import Testing

struct ServerAppStateApprovalQueueTests {
  @MainActor
  @Test func approvalRequestedDoesNotOverrideActiveQueueHead() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-approval-request-order"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-1"),
    ])
    await Task.yield()

    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-1",
      sessionId: sessionId,
      type: .exec
    )

    state.connection.onApprovalRequested?(
      sessionId,
      makeApprovalRequest(id: "req-2", sessionId: sessionId, type: .exec),
      nil
    )
    await Task.yield()

    #expect(state.session(sessionId).pendingApproval?.id == "req-1")
    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == "req-1")
  }

  @MainActor
  @Test func approveToolUsesSummaryQueueHeadAsSourceOfTruth() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-summary-head"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-head"),
    ])
    await Task.yield()
    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-observable",
      sessionId: sessionId,
      type: .exec
    )

    // Session summary is authoritative for queue head when present.
    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == "req-head")

    let result = state.approveTool(
      sessionId: sessionId,
      requestId: "req-observable",
      decision: "approved"
    )

    switch result {
      case .dispatched:
        Issue.record("Expected stale result when request is not the summary queue head.")
      case let .stale(nextPendingRequestId):
        #expect(nextPendingRequestId == "req-head")
    }
  }

  @MainActor
  @Test func nextPendingApprovalIgnoresStaleObservableWhenSummaryIsNotBlocked() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-summary-not-blocked"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: nil),
    ])
    await Task.yield()

    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-stale-observable",
      sessionId: sessionId,
      type: .exec
    )

    #expect(state.sessions.first(where: { $0.id == sessionId })?.workStatus == .working)
    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == nil)
  }

  @MainActor
  @Test func nextPendingApprovalDoesNotFallbackToObservableWhenSummaryHasNoPendingId() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-summary-blocked-no-id"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: nil, workStatus: .permission),
    ])
    await Task.yield()

    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-observable",
      sessionId: sessionId,
      type: .exec
    )

    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == nil)
  }

  @MainActor
  @Test func approvalResultClearsStaleObservableWhenDeltaNoLongerBlocked() async throws {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-clear-stale-observable-delta"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-1"),
    ])
    await Task.yield()

    let obs = state.session(sessionId)
    obs.pendingApproval = makeApprovalRequest(id: "req-1", sessionId: sessionId, type: .exec)

    let deltaData = #"{"work_status":"waiting"}"#.data(using: .utf8)!
    let delta = try JSONDecoder().decode(ServerStateChanges.self, from: deltaData)

    state.connection.onSessionDelta?(
      sessionId,
      delta
    )
    await Task.yield()

    #expect(state.nextPendingApprovalRequestId(sessionId: sessionId) == nil)
    #expect(obs.pendingApproval == nil)
  }

  @MainActor
  @Test func approveToolLeavesPendingApprovalServerAuthoritative() {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-approval-queue"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-1"),
    ])

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
  @Test func approveToolDeduplicatesRepeatedSubmissionForSamePendingRequest() {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-approval-dedupe"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-1"),
    ])

    state.session(sessionId).pendingApproval = makeApprovalRequest(
      id: "req-1",
      sessionId: sessionId,
      type: .exec
    )

    let first = state.approveTool(sessionId: sessionId, requestId: "req-1", decision: "approved")
    let second = state.approveTool(sessionId: sessionId, requestId: "req-1", decision: "approved")

    switch first {
      case .dispatched:
        #expect(true)
      case .stale:
        Issue.record("Expected first approval dispatch to succeed.")
    }

    switch second {
      case let .stale(nextPendingRequestId):
        #expect(nextPendingRequestId == "req-1")
      case .dispatched:
        Issue.record("Expected duplicate approval dispatch to be ignored.")
    }
  }

  @MainActor
  @Test func approveToolReturnsStaleWithNextPendingRequestId() {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-approval-stale"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-current"),
    ])

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

  // MARK: - Approval Version Gating

  @MainActor
  @Test func approvalVersionGatesStaleApprovalRequested() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-version-gate-stale"

    let obs = state.session(sessionId)
    obs.approvalVersion = 5
    obs.pendingApproval = makeApprovalRequest(id: "req-current", sessionId: sessionId, type: .exec)

    state.connection.onApprovalRequested?(
      sessionId,
      makeApprovalRequest(id: "req-stale", sessionId: sessionId, type: .exec),
      3
    )
    await Task.yield()

    #expect(obs.pendingApproval?.id == "req-current")
    #expect(obs.approvalVersion == 5)
  }

  @MainActor
  @Test func approvalVersionAcceptsNewerApprovalRequested() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-version-gate-newer"

    let obs = state.session(sessionId)
    obs.approvalVersion = 3

    state.connection.onApprovalRequested?(
      sessionId,
      makeApprovalRequest(id: "req-newer", sessionId: sessionId, type: .exec),
      5
    )
    await Task.yield()

    #expect(obs.pendingApproval?.id == "req-newer")
    #expect(obs.approvalVersion == 5)
  }

  @MainActor
  @Test func approvalDecisionResultUpdatesVersionAndClearsPending() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-decision-version"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-1"),
    ])
    await Task.yield()

    let obs = state.session(sessionId)
    obs.pendingApproval = makeApprovalRequest(id: "req-1", sessionId: sessionId, type: .exec)

    state.connection.onApprovalDecisionResult?(sessionId, "req-1", "applied", nil, 10)
    await Task.yield()

    #expect(obs.approvalVersion == 10)
    #expect(obs.pendingApproval == nil)
    #expect(state.sessions.first(where: { $0.id == sessionId })?.pendingApprovalId == nil)
    #expect(state.sessions.first(where: { $0.id == sessionId })?.attentionReason == Session.AttentionReason.none)
  }

  @MainActor
  @Test func approvalDecisionResultPromotesQueuedRequestFromCache() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-decision-promotes-queued"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-1"),
    ])
    await Task.yield()

    let obs = state.session(sessionId)
    obs.pendingApproval = makeApprovalRequest(id: "req-1", sessionId: sessionId, type: .exec)

    state.connection.onApprovalRequested?(
      sessionId,
      makeApprovalRequest(id: "req-2", sessionId: sessionId, type: .exec),
      9
    )
    await Task.yield()

    #expect(obs.pendingApproval?.id == "req-1")

    state.connection.onApprovalDecisionResult?(sessionId, "req-1", "applied", "req-2", 10)
    await Task.yield()

    #expect(obs.approvalVersion == 10)
    #expect(obs.pendingApproval?.id == "req-2")
    #expect(state.sessions.first(where: { $0.id == sessionId })?.pendingApprovalId == "req-2")
    #expect(state.sessions.first(where: { $0.id == sessionId })?.pendingPermissionDetail == "echo test")
    #expect(state.sessions.first(where: { $0.id == sessionId })?.attentionReason == .awaitingPermission)
  }

  @MainActor
  @Test func approvalDecisionResultDoesNotClearDifferentPending() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-decision-mismatch"

    let obs = state.session(sessionId)
    obs.pendingApproval = makeApprovalRequest(id: "req-2", sessionId: sessionId, type: .exec)

    // Decision arrives for req-1, but req-2 is now pending
    state.connection.onApprovalDecisionResult?(sessionId, "req-1", "applied", nil, 10)
    await Task.yield()

    #expect(obs.approvalVersion == 10)
    #expect(obs.pendingApproval?.id == "req-2")
  }

  @MainActor
  @Test func approvalRequestedAcceptsNilVersionForBackwardsCompat() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-nil-version"

    let obs = state.session(sessionId)
    obs.approvalVersion = 5

    // Older server sends nil version — should be accepted regardless
    state.connection.onApprovalRequested?(
      sessionId,
      makeApprovalRequest(id: "req-no-version", sessionId: sessionId, type: .exec),
      nil
    )
    await Task.yield()

    #expect(obs.pendingApproval?.id == "req-no-version")
    // Version unchanged since incoming was nil
    #expect(obs.approvalVersion == 5)
  }

  @MainActor
  @Test func answerQuestionDispatchesForActivePending() {
    let state = ServerAppState()
    state.setup()
    let sessionId = "session-answer-question"

    state.connection.onSessionsList?([
      makeSessionSummary(id: sessionId, pendingApprovalId: "req-question", workStatus: .question),
    ])

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

    #expect(result == .dispatched)
    #expect(state.session(sessionId).pendingApproval?.id == "req-question")
  }

  // MARK: - Helpers

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

  private func makeSessionSummary(
    id: String,
    pendingApprovalId: String?,
    workStatus: ServerWorkStatus? = nil
  ) -> ServerSessionSummary {
    let resolvedWorkStatus: ServerWorkStatus = workStatus ?? (pendingApprovalId == nil ? .working : .permission)
    let hasPending = pendingApprovalId != nil
    return ServerSessionSummary(
      id: id,
      provider: .codex,
      projectPath: "/tmp/project",
      transcriptPath: nil,
      projectName: nil,
      model: nil,
      customName: nil,
      summary: nil,
      status: .active,
      workStatus: resolvedWorkStatus,
      tokenUsage: nil,
      tokenUsageSnapshotKind: nil,
      hasPendingApproval: hasPending,
      codexIntegrationMode: nil,
      claudeIntegrationMode: nil,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: nil,
      pendingToolName: hasPending ? "Bash" : nil,
      pendingToolInput: hasPending ? #"{"command":"echo test"}"# : nil,
      pendingQuestion: nil,
      pendingApprovalId: pendingApprovalId,
      startedAt: "2026-02-24T00:00:00Z",
      lastActivityAt: "2026-02-24T00:00:00Z",
      gitBranch: nil,
      gitSha: nil,
      currentCwd: nil,
      firstPrompt: nil,
      lastMessage: nil,
      effort: nil,
      approvalVersion: nil,
      repositoryRoot: nil,
      isWorktree: nil,
      worktreeId: nil
    )
  }
}
