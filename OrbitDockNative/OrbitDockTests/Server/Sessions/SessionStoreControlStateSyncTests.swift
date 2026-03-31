import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionStoreControlStateSyncTests {
  @Test func approvalEventsKeepSummaryAndDetailStateAligned() throws {
    let store = SessionStore.preview()
    try store.handleSessionDetailSnapshot(
      ServerSessionDetailSnapshotPayload(
        revision: 1,
        session: decodeSessionState(detailSnapshotJSON)
      )
    )

    let request = ServerApprovalRequest(
      id: "req-1",
      sessionId: "session-1",
      type: .exec,
      command: "git status"
    )

    store.routeEvent(
      .approvalRequested(sessionId: "session-1", request: request, approvalVersion: 2)
    )

    let detailAfterRequest = store.session("session-1")
    #expect(detailAfterRequest.pendingApprovalId == "req-1")
    #expect(detailAfterRequest.attentionReason == Session.AttentionReason.awaitingPermission)
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

    let detailAfterDecision = store.session("session-1")
    #expect(detailAfterDecision.pendingApproval == nil)
    #expect(detailAfterDecision.pendingApprovalId == nil)
    #expect(detailAfterDecision.attentionReason == Session.AttentionReason.none)
    #expect(detailAfterDecision.approvalVersion == 3)
  }

  @Test func sessionDeltaKeepsConfigAndPendingApprovalStateInSync() throws {
    let store = SessionStore.preview()
    try store.handleSessionDetailSnapshot(
      ServerSessionDetailSnapshotPayload(
        revision: 1,
        session: decodeSessionState(detailSnapshotJSON)
      )
    )

    try store.handleSessionComposerSnapshot(
      ServerSessionComposerSnapshotPayload(
        revision: 2,
        session: decodeSessionState(
          """
          {
            "id": "session-1",
            "provider": "claude",
            "project_path": "/tmp/project",
            "status": "active",
            "work_status": "question",
            "control_mode": "direct",
            "lifecycle_state": "open",
            "accepts_user_input": true,
            "steerable": false,
            "rows": [],
            "total_row_count": 0,
            "has_more_before": false,
            "token_usage": {
              "input_tokens": 0,
              "output_tokens": 0,
              "cached_tokens": 0,
              "context_window": 0
            },
            "token_usage_snapshot_kind": "unknown",
            "allow_bypass_permissions": false,
            "turn_count": 0,
            "turn_diffs": [],
            "subagents": [],
            "is_worktree": false,
            "unread_count": 0,
            "has_pending_approval": true,
            "pending_approval": {
              "id": "req-2",
              "session_id": "session-1",
              "type": "question",
              "question": "Ship it?"
            },
            "approval_version": 5,
            "permission_mode": "plan",
            "autonomy": "unrestricted",
            "autonomy_configured_on_server": true,
            "sandbox_mode": "danger-full-access",
            "approval_policy": "never",
            "claude_integration_mode": "direct"
          }
          """
        )
      )
    )

    let detail = store.session("session-1")
    #expect(detail.pendingApprovalId == "req-2")
    #expect(detail.attentionReason == Session.AttentionReason.awaitingQuestion)
    #expect(detail.pendingApproval?.id == "req-2")
    #expect(detail.approvalVersion == 5)
    #expect(detail.permissionMode == .plan)
    #expect(detail.autonomy == .unrestricted)
    #expect(detail.autonomyConfiguredOnServer == true)
  }

  @Test func sessionDeltaUpdatesWorkingStateWithoutRefetch() throws {
    let store = SessionStore.preview()
    try store.handleSessionComposerSnapshot(
      ServerSessionComposerSnapshotPayload(
        revision: 1,
        session: decodeSessionState(
          """
          {
            "id": "session-1",
            "provider": "codex",
            "project_path": "/tmp/project",
            "status": "active",
            "work_status": "waiting",
            "control_mode": "direct",
            "lifecycle_state": "open",
            "accepts_user_input": true,
            "steerable": false,
            "rows": [],
            "total_row_count": 0,
            "has_more_before": false,
            "token_usage": {
              "input_tokens": 0,
              "output_tokens": 0,
              "cached_tokens": 0,
              "context_window": 0
            },
            "token_usage_snapshot_kind": "unknown",
            "allow_bypass_permissions": false,
            "turn_count": 0,
            "turn_diffs": [],
            "subagents": [],
            "is_worktree": false,
            "unread_count": 0
          }
          """
        )
      )
    )

    store.routeEvent(
      .sessionDelta(
        sessionId: "session-1",
        changes: ServerStateChanges(
          workStatus: .working,
          acceptsUserInput: true,
          steerable: true
        )
      )
    )

    let session = store.session("session-1")
    #expect(session.workStatus == .working)
    #expect(session.steerable == true)
    #expect(session.displayStatus == .working)
  }

  @Test func sessionSnapshotHydratesSubagentMetadataIntoDetailState() throws {
    let store = SessionStore.preview()

    try store.handleSessionDetailSnapshot(
      ServerSessionDetailSnapshotPayload(
        revision: 1,
        session: decodeSessionState(
          """
          {
            "id": "session-1",
            "provider": "codex",
            "project_path": "/tmp/project",
            "status": "active",
            "work_status": "working",
            "control_mode": "direct",
            "lifecycle_state": "open",
            "accepts_user_input": true,
            "steerable": false,
            "rows": [],
            "total_row_count": 0,
            "has_more_before": false,
            "token_usage": {
              "input_tokens": 0,
              "output_tokens": 0,
              "cached_tokens": 0,
              "context_window": 0
            },
            "token_usage_snapshot_kind": "unknown",
            "allow_bypass_permissions": false,
            "turn_count": 0,
            "turn_diffs": [],
            "is_worktree": false,
            "unread_count": 0,
            "subagents": [
              {
                "id": "worker-1",
                "agent_type": "explorer",
                "started_at": "2026-03-10T10:00:00Z",
                "provider": "codex",
                "label": "Repo Scout",
                "status": "running",
                "task_summary": "Map the repository structure",
                "parent_subagent_id": "root-worker",
                "model": "gpt-5"
              }
            ]
          }
          """
        )
      )
    )

    let detail = store.session("session-1")
    let worker = try #require(detail.subagents.first)
    #expect(worker.id == "worker-1")
    #expect(worker.provider == .codex)
    #expect(worker.label == "Repo Scout")
    #expect(worker.status == .running)
    #expect(worker.taskSummary == "Map the repository structure")
    #expect(worker.parentSubagentId == "root-worker")
    #expect(worker.model == "gpt-5")
  }

  @Test func sessionEndedEventMarksLifecycleAsEndedImmediately() throws {
    let store = SessionStore.preview()
    try store.handleSessionDetailSnapshot(
      ServerSessionDetailSnapshotPayload(
        revision: 1,
        session: decodeSessionState(detailSnapshotJSON)
      )
    )

    store.routeEvent(.sessionEnded(sessionId: "session-1", reason: "user_requested"))

    let session = store.session("session-1")
    #expect(session.status == .ended)
    #expect(session.workStatus == .ended)
    #expect(session.lifecycleState == .ended)
    #expect(session.acceptsUserInput == false)
    #expect(session.steerable == false)
    #expect(session.displayStatus == .ended)
  }

  private var detailSnapshotJSON: String {
    """
    {
      "id": "session-1",
      "provider": "claude",
      "project_path": "/tmp/project",
      "status": "active",
      "work_status": "waiting",
      "control_mode": "direct",
      "lifecycle_state": "open",
      "accepts_user_input": true,
      "steerable": false,
      "rows": [],
      "total_row_count": 0,
      "has_more_before": false,
      "token_usage": {
        "input_tokens": 0,
        "output_tokens": 0,
        "cached_tokens": 0,
        "context_window": 0
      },
      "token_usage_snapshot_kind": "unknown",
      "allow_bypass_permissions": false,
      "turn_count": 0,
      "turn_diffs": [],
      "subagents": [],
      "is_worktree": false,
      "unread_count": 0,
      "has_pending_approval": false,
      "claude_integration_mode": "direct"
    }
    """
  }

  private func decodeSessionState(_ json: String) throws -> ServerSessionState {
    try JSONDecoder().decode(ServerSessionState.self, from: Data(json.utf8))
  }
}
