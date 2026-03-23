import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct SessionStateProjectionTests {
  @Test func sessionObservableApplyPendingApprovalSetsPermissionFields() {
    let observable = SessionObservable(id: "session-1")

    observable.applyPendingApproval(execApprovalRequest())

    #expect(observable.pendingApprovalId == "req-1")
    #expect(observable.pendingToolName == "Bash")
    #expect(observable.pendingToolInput == #"{"command":"git status"}"#)
    #expect(observable.pendingPermissionDetail == "git status")
    #expect(observable.pendingQuestion == nil)
    #expect(observable.attentionReason == .awaitingPermission)
    #expect(observable.workStatus == .permission)
  }

  @Test func sessionObservableClearPendingApprovalResetsAttentionWhenRequested() {
    let observable = SessionObservable(id: "session-1")
    observable.applyPendingApproval(questionApprovalRequest())

    observable.clearPendingApprovalDetails(resetAttention: true)

    #expect(observable.pendingApproval == nil)
    #expect(observable.pendingApprovalId == nil)
    #expect(observable.pendingToolName == nil)
    #expect(observable.pendingPermissionDetail == nil)
    #expect(observable.pendingQuestion == nil)
    #expect(observable.attentionReason == .none)
    #expect(observable.workStatus == .working)
  }

  @Test func sessionObservablePopulateFromPreviewSessionMirrorsDetailFields() {
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

    observable.populateFromPreviewSession(session)

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

  @Test func sessionObservableApplyServerDeltaUpdatesSubagents() {
    let observable = SessionObservable(id: "session-1")
    let worker = ServerSubagentInfo(
      id: "worker-1",
      agentType: "worker",
      startedAt: "2026-03-12T10:00:00Z",
      endedAt: nil,
      provider: .codex,
      label: "Descartes",
      status: .running,
      taskSummary: "Check whether Makefile exists",
      resultSummary: nil,
      errorSummary: nil,
      parentSubagentId: nil,
      model: "gpt-5.4",
      lastActivityAt: "2026-03-12T10:00:01Z"
    )

    observable.applyServerDelta(
      ServerStateChanges(subagents: [worker])
    )

    #expect(observable.subagents.count == 1)
    #expect(observable.subagents.first?.id == "worker-1")
    #expect(observable.subagents.first?.status == .running)
  }

  @Test func sessionObservableApplyServerDeltaPreservesInterruptedSubagentStatus() {
    let observable = SessionObservable(id: "session-1")
    let worker = ServerSubagentInfo(
      id: "worker-1",
      agentType: "worker",
      startedAt: "2026-03-12T10:00:00Z",
      endedAt: nil,
      provider: .codex,
      label: "Descartes",
      status: .interrupted,
      taskSummary: "Resume after interruption",
      resultSummary: nil,
      errorSummary: nil,
      parentSubagentId: nil,
      model: "gpt-5.4",
      lastActivityAt: "2026-03-12T10:00:01Z"
    )

    observable.applyServerDelta(
      ServerStateChanges(subagents: [worker])
    )

    #expect(observable.subagents.first?.status == .interrupted)
  }

  @Test func sessionObservableApplyServerSnapshotHydratesDiffPlanTurnAndSubagentFields() throws {
    let observable = SessionObservable(id: "session-1")

    let state = try decodeServerSessionState(
      """
      {
        "id": "session-1",
        "provider": "claude",
        "project_path": "/tmp/project",
        "status": "active",
        "work_status": "working",
        "steerable": true,
        "token_usage": {"input_tokens": 0, "output_tokens": 0, "cached_tokens": 0, "context_window": 0},
        "token_usage_snapshot_kind": "lifetime_totals",
        "turn_count": 3,
        "current_turn_id": "turn-42",
        "current_diff": "diff --git a/file.swift",
        "cumulative_diff": "cumulative diff content",
        "current_plan": "[{\\"step\\":\\"Refactor\\",\\"status\\":\\"inProgress\\"}]",
        "turn_diffs": [
          {
            "turn_id": "turn-42",
            "diff": "diff --git a/file.swift b/file.swift",
            "input_tokens": 10,
            "output_tokens": 5,
            "cached_tokens": 2,
            "context_window": 100000
          }
        ],
        "subagents": [
          {
            "id": "worker-1",
            "agent_type": "worker",
            "started_at": "2026-03-22T10:00:00Z",
            "provider": "codex",
            "label": "Leibniz",
            "status": "running",
            "task_summary": "Check Makefile",
            "model": "gpt-5.4",
            "last_activity_at": "2026-03-22T10:00:01Z"
          }
        ]
      }
      """
    )

    observable.applyServerSnapshot(state)

    #expect(observable.diff == "diff --git a/file.swift")
    #expect(observable.cumulativeDiff == "cumulative diff content")
    #expect(observable.plan == #"[{"step":"Refactor","status":"inProgress"}]"#)
    #expect(observable.turnDiffs.count == 1)
    #expect(observable.turnDiffs.first?.turnId == "turn-42")
    #expect(observable.turnDiffs.first?.diff == "diff --git a/file.swift b/file.swift")
    #expect(observable.currentTurnId == "turn-42")
    #expect(observable.turnCount == 3)
    #expect(observable.subagents.count == 1)
    #expect(observable.subagents.first?.id == "worker-1")
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
      ),
    ]
    observable.pendingShellContext = [
      ShellContextEntry(command: "pwd", output: "/tmp/project", exitCode: 0, timestamp: Date()),
    ]

    observable.trimInactiveDetailPayloads()

    #expect(observable.turnDiffs.isEmpty)
    #expect(observable.diff == nil)
    #expect(observable.plan == nil)
    #expect(observable.currentTurnId == nil)
    #expect(observable.reviewComments.isEmpty)
    #expect(observable.pendingShellContext.isEmpty)
  }

  @Test func sessionObservableApplyServerDeltaAppliesSharedFields() throws {
    let changes = try decodeChanges(
      """
      {
        "status": "active",
        "work_status": "working",
        "token_usage": {
          "input_tokens": 120,
          "output_tokens": 45,
          "cached_tokens": 12,
          "context_window": 200000
        },
        "token_usage_snapshot_kind": "context_turn",
        "current_diff": "diff --git a/file.swift b/file.swift",
        "current_plan": "[{\\"step\\":\\"Refactor\\",\\"status\\":\\"inProgress\\"}]",
        "custom_name": "Pinned Session",
        "summary": "Refactor the client runtime",
        "first_prompt": "Please fix the store",
        "last_message": "Latest assistant message",
        "codex_integration_mode": "direct",
        "git_branch": "main",
        "git_sha": "abc123",
        "current_cwd": "/tmp/project",
        "model": "gpt-5",
        "effort": "high",
        "current_turn_id": "turn-123",
        "turn_count": 8,
        "last_activity_at": "1234",
        "repository_root": "/tmp/repo",
        "is_worktree": true,
        "unread_count": 7
      }
      """
    )

    let observable = SessionObservable(id: "session-1")
    observable.promptSuggestions = ["keep me?"]

    observable.applyServerDelta(changes)

    #expect(observable.workStatus == .working)
    #expect(observable.attentionReason == .none)
    #expect(observable.totalTokens == 165)
    #expect(observable.tokenUsageSnapshotKind == .contextTurn)
    #expect(observable.diff == "diff --git a/file.swift b/file.swift")
    #expect(observable.plan == #"[{"step":"Refactor","status":"inProgress"}]"#)
    #expect(observable.customName == "Pinned Session")
    #expect(observable.turnCount == 8)
    #expect(observable.currentTurnId == "turn-123")
    #expect(observable.promptSuggestions.isEmpty)
    #expect(observable.unreadCount == 7)
  }

  @Test func sessionObservableApplyTokenUsageKeepsSnapshotKindInSync() {
    let usage = ServerTokenUsage(
      inputTokens: 50,
      outputTokens: 25,
      cachedTokens: 10,
      contextWindow: 1_000
    )

    let observable = SessionObservable(id: "session-1")

    observable.applyTokenUsage(usage, snapshotKind: .lifetimeTotals)

    #expect(observable.inputTokens == 50)
    #expect(observable.outputTokens == 25)
    #expect(observable.cachedTokens == 10)
    #expect(observable.contextWindow == 1_000)
    #expect(observable.totalTokens == 75)
    #expect(observable.tokenUsageSnapshotKind == .lifetimeTotals)
    #expect(observable.tokenUsage?.inputTokens == 50)
  }

  @Test func turnDiffSnapshotProjectionUpsertsDetailDiffAndKeepsUsageInSync() {
    let projection = SessionTurnDiffSnapshotProjection.fromTurnDiffSnapshot(
      turnId: "turn-1",
      diff: "diff --git a/file.swift b/file.swift",
      inputTokens: 40,
      outputTokens: 15,
      cachedTokens: 5,
      contextWindow: 2_000,
      snapshotKind: .contextTurn
    )

    let observable = SessionObservable(id: "session-1")

    observable.applyTurnDiffSnapshot(projection)

    #expect(observable.turnDiffs.count == 1)
    #expect(observable.turnDiffs.first?.turnId == "turn-1")
    #expect(observable.turnDiffs.first?.diff == "diff --git a/file.swift b/file.swift")
    #expect(observable.inputTokens == 40)
    #expect(observable.outputTokens == 15)
    #expect(observable.cachedTokens == 5)
    #expect(observable.contextWindow == 2_000)
    #expect(observable.tokenUsageSnapshotKind == .contextTurn)
  }

  @Test func turnDiffSnapshotProjectionReplacesExistingTurnById() {
    let observable = SessionObservable(id: "session-1")
    observable.turnDiffs = [
      ServerTurnDiff(
        turnId: "turn-1",
        diff: "old diff",
        inputTokens: 1,
        outputTokens: 2,
        cachedTokens: 3,
        contextWindow: 4
      ),
    ]

    let projection = SessionTurnDiffSnapshotProjection.fromTurnDiffSnapshot(
      turnId: "turn-1",
      diff: "new diff",
      inputTokens: 10,
      outputTokens: 11,
      cachedTokens: 12,
      contextWindow: 13,
      snapshotKind: .lifetimeTotals
    )

    observable.applyTurnDiffSnapshot(projection)

    #expect(observable.turnDiffs.count == 1)
    #expect(observable.turnDiffs.first?.diff == "new diff")
    #expect(observable.inputTokens == 10)
    #expect(observable.outputTokens == 11)
    #expect(observable.cachedTokens == 12)
    #expect(observable.contextWindow == 13)
    #expect(observable.tokenUsageSnapshotKind == .lifetimeTotals)
  }

  @Test func sessionObservableTokenUsageSemanticsMatchSessionStruct() {
    let session = Session(
      id: "session-1",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      provider: .claude,
      inputTokens: 2_400,
      outputTokens: 100,
      cachedTokens: 600,
      contextWindow: 8_000,
      tokenUsageSnapshotKind: .mixedLegacy
    )
    let observable = SessionObservable(id: "session-1")

    observable.populateFromPreviewSession(session)

    #expect(observable.effectiveContextInputTokens == session.effectiveContextInputTokens)
    #expect(observable.contextFillPercent == session.contextFillPercent)
    #expect(observable.effectiveCacheHitPercent == session.effectiveCacheHitPercent)
    #expect(observable.hasTokenUsage)
    #expect(SessionTokenUsageSemantics.hasTokenUsage(
      inputTokens: session.inputTokens,
      outputTokens: session.outputTokens,
      cachedTokens: session.cachedTokens
    ))
  }

  @Test func sessionObservableStreamingRowUpdateOnlyBumpsContentRevision() {
    let observable = SessionObservable(id: "session-1")
    let initialRow = assistantRow(id: "assistant-1", sequence: 1, content: "hello", isStreaming: true)

    observable.applyConversationPage(
      rows: [initialRow],
      hasMoreBefore: false,
      oldestSequence: initialRow.sequence,
      isBootstrap: true
    )

    let initialStructureRevision = observable.rowEntriesStructureRevision
    let initialContentRevision = observable.rowEntriesContentRevision

    let updatedRow = assistantRow(id: "assistant-1", sequence: 1, content: "hello world", isStreaming: true)
    observable.applyRowsChanged(upserted: [updatedRow], removedIds: [])

    #expect(observable.rowEntries.count == 1)
    #expect(observable.rowEntriesStructureRevision == initialStructureRevision)
    #expect(observable.rowEntriesContentRevision == initialContentRevision + 1)
    #expect(observable.lastChangedRowEntries.map(\.id) == ["assistant-1"])
    #expect(observable.rowEntries.first?.id == "assistant-1")
  }

  @Test func sessionObservableInsertedRowBumpsStructureRevision() {
    let observable = SessionObservable(id: "session-1")
    let firstRow = assistantRow(id: "assistant-1", sequence: 1, content: "hello")

    observable.applyConversationPage(
      rows: [firstRow],
      hasMoreBefore: false,
      oldestSequence: firstRow.sequence,
      isBootstrap: true
    )

    let initialStructureRevision = observable.rowEntriesStructureRevision
    let initialContentRevision = observable.rowEntriesContentRevision

    let secondRow = assistantRow(id: "assistant-2", sequence: 2, content: "world")
    observable.applyRowsChanged(upserted: [secondRow], removedIds: [])

    #expect(observable.rowEntries.count == 2)
    #expect(observable.rowEntriesStructureRevision == initialStructureRevision + 1)
    #expect(observable.rowEntriesContentRevision == initialContentRevision + 1)
    #expect(observable.lastChangedRowEntries.map(\.id) == ["assistant-2"])
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
        ),
      ]
    )
  }

  private func decodeChanges(_ json: String) throws -> ServerStateChanges {
    try JSONDecoder().decode(ServerStateChanges.self, from: Data(json.utf8))
  }

  private func decodeServerSessionState(_ json: String) throws -> ServerSessionState {
    try JSONDecoder().decode(ServerSessionState.self, from: Data(json.utf8))
  }

  private func assistantRow(
    id: String,
    sequence: UInt64,
    content: String,
    isStreaming: Bool = false
  ) -> ServerConversationRowEntry {
    ServerConversationRowEntry(
      sessionId: "session-1",
      sequence: sequence,
      turnId: nil,
      turnStatus: .active,
      row: .assistant(ServerConversationMessageRow(
        id: id,
        content: content,
        turnId: nil,
        timestamp: nil,
        isStreaming: isStreaming,
        images: nil,
        memoryCitation: nil
      ))
    )
  }
}
