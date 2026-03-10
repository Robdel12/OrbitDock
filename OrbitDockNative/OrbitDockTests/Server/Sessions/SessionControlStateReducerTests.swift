import Foundation
import Testing
@testable import OrbitDock

@MainActor
struct SessionControlStateReducerTests {
  @Test func snapshotSeedsApprovalAndControlConfigurationConsistently() throws {
    let transition = SessionControlStateReducer.snapshotTransition(
      current: baseState(),
      snapshot: try decodeSnapshot(
        """
        {
          "id": "session-1",
          "provider": "claude",
          "project_path": "/tmp/project",
          "status": "active",
          "work_status": "waiting",
          "messages": [],
          "token_usage": {
            "input_tokens": 0,
            "output_tokens": 0,
            "cached_tokens": 0,
            "context_window": 0
          },
          "token_usage_snapshot_kind": "unknown",
          "pending_approval": {
            "id": "req-1",
            "session_id": "session-1",
            "type": "exec",
            "command": "git status"
          },
          "approval_policy": "never",
          "sandbox_mode": "danger-full-access",
          "permission_mode": "plan",
          "approval_version": 8,
          "turn_count": 0
        }
        """
      ),
      supportsServerControlConfiguration: true
    )

    #expect(transition.nextState.approvalVersion == 8)
    #expect(transition.nextState.pendingApprovalId == "req-1")
    #expect(transition.nextState.approvalPolicy == "never")
    #expect(transition.nextState.sandboxMode == "danger-full-access")
    #expect(transition.nextState.autonomy == .unrestricted)
    #expect(transition.nextState.autonomyConfiguredOnServer == true)
    #expect(transition.nextState.permissionMode == .plan)

    guard case let .set(request) = transition.detailApprovalChange else {
      Issue.record("Expected snapshot to seed pending approval details")
      return
    }
    #expect(request.id == "req-1")
  }

  @Test func staleApprovalDeltaIsIgnoredWithoutDroppingCurrentPendingApproval() throws {
    let transition = SessionControlStateReducer.deltaTransition(
      current: SessionControlState(
        approvalVersion: 9,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        permissionModeRaw: "default",
        autonomy: .autonomous,
        autonomyConfiguredOnServer: true,
        pendingApprovalId: "req-current"
      ),
      changes: try decodeChanges(
        """
        {
          "pending_approval": {
            "id": "req-stale",
            "session_id": "session-1",
            "type": "exec",
            "command": "rm -rf /tmp"
          },
          "approval_version": 4
        }
        """
      ),
      summaryStillBlocked: true
    )

    #expect(transition.nextState.approvalVersion == 9)
    #expect(transition.nextState.pendingApprovalId == "req-current")
    #expect(approvalChangeID(transition.summaryApprovalChange) == nil)
    #expect(approvalChangeID(transition.detailApprovalChange) == nil)
  }

  @Test func approvalDeltaAppliesSummaryAndDetailFromOneTransition() throws {
    let transition = SessionControlStateReducer.deltaTransition(
      current: baseState(),
      changes: try decodeChanges(
        """
        {
          "pending_approval": {
            "id": "req-2",
            "session_id": "session-1",
            "type": "question",
            "question": "Ship it?"
          },
          "approval_version": 2
        }
        """
      ),
      summaryStillBlocked: false
    )

    #expect(transition.nextState.approvalVersion == 2)
    #expect(transition.nextState.pendingApprovalId == "req-2")
    #expect(approvalChangeID(transition.summaryApprovalChange) == "req-2")
    #expect(approvalChangeID(transition.detailApprovalChange) == "req-2")
  }

  @Test func configChangesRecomputeAutonomyDeterministically() throws {
    let transition = SessionControlStateReducer.deltaTransition(
      current: SessionControlState(
        approvalVersion: 1,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        permissionModeRaw: "plan",
        autonomy: .autonomous,
        autonomyConfiguredOnServer: true,
        pendingApprovalId: nil
      ),
      changes: try decodeChanges(
        """
        {
          "approval_policy": "never",
          "sandbox_mode": "workspace-write"
        }
        """
      ),
      summaryStillBlocked: false
    )

    #expect(transition.nextState.autonomy == AutonomyLevel.fullAuto)
    #expect(transition.nextState.autonomyConfiguredOnServer == true)
    #expect(transition.nextState.permissionMode == .plan)
  }

  @Test func approvalDecisionClearsPendingApprovalWhenQueueHeadResolves() {
    let transition = SessionControlStateReducer.approvalDecisionTransition(
      current: SessionControlState(
        approvalVersion: 2,
        approvalPolicy: nil,
        sandboxMode: nil,
        permissionModeRaw: "default",
        autonomy: .autonomous,
        autonomyConfiguredOnServer: true,
        pendingApprovalId: "req-2"
      ),
      requestId: "req-2",
      activeRequestId: nil,
      version: 3
    )

    #expect(transition.nextState.approvalVersion == 3)
    #expect(transition.nextState.pendingApprovalId == nil)
    if case .clear(let resetAttention) = transition.summaryApprovalChange {
      #expect(resetAttention == true)
    } else {
      Issue.record("Expected summary approval change to clear")
    }
    if case .clear(let resetAttention) = transition.detailApprovalChange {
      #expect(resetAttention == true)
    } else {
      Issue.record("Expected detail approval change to clear")
    }
  }

  private func baseState() -> SessionControlState {
    SessionControlState(
      approvalVersion: 0,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionModeRaw: "default",
      autonomy: .autonomous,
      autonomyConfiguredOnServer: false,
      pendingApprovalId: nil
    )
  }

  private func approvalChangeID(_ change: SessionPendingApprovalChange) -> String? {
    if case let .set(request) = change {
      return request.id
    }
    return nil
  }

  private func decodeSnapshot(_ json: String) throws -> ServerSessionState {
    try JSONDecoder().decode(ServerSessionState.self, from: Data(json.utf8))
  }

  private func decodeChanges(_ json: String) throws -> ServerStateChanges {
    try JSONDecoder().decode(ServerStateChanges.self, from: Data(json.utf8))
  }
}
