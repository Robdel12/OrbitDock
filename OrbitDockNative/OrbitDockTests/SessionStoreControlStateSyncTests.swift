import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct SessionStoreControlStateSyncTests {
  @Test func approvalEventsKeepSummaryAndDetailStateAligned() throws {
    let store = SessionStore()
    store.routeEvent(.sessionsList([try decodeSummary(sessionSummaryJSON)]))

    let request = ServerApprovalRequest(
      id: "req-1",
      sessionId: "session-1",
      type: .exec,
      command: "git status"
    )

    store.routeEvent(.approvalRequested(sessionId: "session-1", request: request, approvalVersion: 2))

    let summaryAfterRequest = try #require(store.sessions.first(where: { $0.id == "session-1" }))
    let detailAfterRequest = store.session("session-1")
    #expect(summaryAfterRequest.pendingApprovalId == "req-1")
    #expect(summaryAfterRequest.attentionReason == .awaitingPermission)
    #expect(detailAfterRequest.pendingApproval?.id == "req-1")
    #expect(detailAfterRequest.approvalVersion == 2)

    store.routeEvent(
      .approvalDecisionResult(
        sessionId: "session-1",
        requestId: "req-1",
        outcome: "approved",
        activeRequestId: nil,
        approvalVersion: 3
      )
    )

    let summaryAfterDecision = try #require(store.sessions.first(where: { $0.id == "session-1" }))
    let detailAfterDecision = store.session("session-1")
    #expect(summaryAfterDecision.pendingApprovalId == nil)
    #expect(summaryAfterDecision.attentionReason == .none)
    #expect(detailAfterDecision.pendingApproval == nil)
    #expect(detailAfterDecision.pendingApprovalId == nil)
    #expect(detailAfterDecision.attentionReason == .none)
    #expect(detailAfterDecision.approvalVersion == 3)
  }

  @Test func sessionDeltaKeepsConfigAndPendingApprovalStateInSync() throws {
    let store = SessionStore()
    store.routeEvent(.sessionsList([try decodeSummary(sessionSummaryJSON)]))

    store.routeEvent(
      .sessionDelta(
        sessionId: "session-1",
        changes: try decodeChanges(
          """
          {
            "approval_policy": "never",
            "sandbox_mode": "danger-full-access",
            "permission_mode": "plan",
            "pending_approval": {
              "id": "req-2",
              "session_id": "session-1",
              "type": "question",
              "question": "Ship it?"
            },
            "approval_version": 5
          }
          """
        )
      )
    )

    let summary = try #require(store.sessions.first(where: { $0.id == "session-1" }))
    let detail = store.session("session-1")
    #expect(summary.pendingApprovalId == "req-2")
    #expect(summary.attentionReason == .awaitingQuestion)
    #expect(detail.pendingApproval?.id == "req-2")
    #expect(detail.approvalVersion == 5)
    #expect(detail.permissionMode == .plan)
    #expect(detail.autonomy == .unrestricted)
    #expect(detail.autonomyConfiguredOnServer == true)
  }

  private var sessionSummaryJSON: String {
    """
    {
      "id": "session-1",
      "provider": "claude",
      "project_path": "/tmp/project",
      "status": "active",
      "work_status": "waiting",
      "has_pending_approval": false,
      "claude_integration_mode": "direct"
    }
    """
  }

  private func decodeSummary(_ json: String) throws -> ServerSessionSummary {
    try JSONDecoder().decode(ServerSessionSummary.self, from: Data(json.utf8))
  }

  private func decodeChanges(_ json: String) throws -> ServerStateChanges {
    try JSONDecoder().decode(ServerStateChanges.self, from: Data(json.utf8))
  }
}
