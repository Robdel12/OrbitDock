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

  @Test func sessionObservableApplySnapshotProjectionMirrorsDetailFields() {
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

    observable.applySnapshotProjection(SessionDetailSnapshotProjection.from(session))

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

  @Test func sessionObservableApplyProjectionUpdatesSubagentsFromServerDelta() {
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

    let projection = SessionStateProjection.from(
      ServerStateChanges(
        status: nil,
        workStatus: nil,
        pendingApproval: nil,
        tokenUsage: nil,
        tokenUsageSnapshotKind: nil,
        currentDiff: nil,
        currentPlan: nil,
        customName: nil,
        summary: nil,
        codexIntegrationMode: nil,
        claudeIntegrationMode: nil,
        approvalPolicy: nil,
        sandboxMode: nil,
        collaborationMode: nil,
        multiAgent: nil,
        personality: nil,
        serviceTier: nil,
        developerInstructions: nil,
        lastActivityAt: nil,
        currentTurnId: nil,
        turnCount: nil,
        gitBranch: nil,
        gitSha: nil,
        currentCwd: nil,
        subagents: [worker],
        firstPrompt: nil,
        lastMessage: nil,
        model: nil,
        effort: nil,
        permissionMode: nil,
        approvalVersion: nil,
        repositoryRoot: nil,
        isWorktree: nil,
        unreadCount: nil
      )
    )

    observable.applyProjection(projection)

    #expect(observable.subagents.count == 1)
    #expect(observable.subagents.first?.id == "worker-1")
    #expect(observable.subagents.first?.status == .running)
  }

  @Test func sessionDetailSnapshotProjectionCapturesDetailMirrorFields() {
    var session = Session(
      id: "session-1",
      endpointId: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
      endpointName: "Primary",
      projectPath: "/tmp/project",
      projectName: "project",
      branch: "main",
      model: "claude-opus",
      transcriptPath: "/tmp/transcript.jsonl",
      status: .active,
      workStatus: .waiting,
      startedAt: Date(timeIntervalSince1970: 100),
      endReason: "completed",
      totalTokens: 321,
      lastActivityAt: Date(timeIntervalSince1970: 200),
      attentionReason: .awaitingReply,
      provider: .claude,
      claudeIntegrationMode: .direct,
      inputTokens: 120,
      outputTokens: 201,
      cachedTokens: 12,
      contextWindow: 200_000
    )
    session.effort = "high"
    session.summary = "Refactor session store"
    session.customName = "Important Session"
    session.firstPrompt = "Please refactor this"
    session.lastMessage = "Latest message"
    session.endedAt = Date(timeIntervalSince1970: 150)
    session.totalCostUSD = 1.25
    session.lastTool = "Bash"
    session.lastToolAt = Date(timeIntervalSince1970: 201)
    session.pendingToolName = "Bash"
    session.pendingToolInput = #"{"command":"pwd"}"#
    session.pendingPermissionDetail = "pwd"
    session.pendingQuestion = "Continue?"
    session.pendingApprovalId = "req-42"
    session.promptCount = 3
    session.toolCount = 9
    session.gitSha = "abc123"
    session.currentCwd = "/tmp/project/subdir"
    session.repositoryRoot = "/tmp/project"
    session.isWorktree = true
    session.worktreeId = "wt-1"
    session.unreadCount = 7

    let projection = SessionDetailSnapshotProjection.from(session)

    #expect(projection.endpointName == "Primary")
    #expect(projection.projectPath == "/tmp/project")
    #expect(projection.model == "claude-opus")
    #expect(projection.pendingApprovalId == "req-42")
    #expect(projection.pendingPermissionDetail == "pwd")
    #expect(projection.totalTokens == 321)
    #expect(projection.totalCostUSD == 1.25)
    #expect(projection.repositoryRoot == "/tmp/project")
    #expect(projection.isWorktree)
    #expect(projection.worktreeId == "wt-1")
    #expect(projection.unreadCount == 7)
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

  @Test func sessionStateProjectionAppliesSharedDeltaFieldsToListAndDetail() throws {
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
    let projection = SessionStateProjection.from(changes)

    var session = Session(
      id: "session-1",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingReply,
      provider: .codex,
      codexIntegrationMode: .direct
    )
    let observable = SessionObservable(id: "session-1")
    observable.promptSuggestions = ["keep me?"]

    session.applyProjection(projection)
    observable.applyProjection(projection)

    #expect(session.workStatus == .working)
    #expect(session.attentionReason == .none)
    #expect(session.totalTokens == 165)
    #expect(session.tokenUsageSnapshotKind == .contextTurn)
    #expect(session.currentDiff == "diff --git a/file.swift b/file.swift")
    #expect(session.customName == "Pinned Session")
    #expect(session.summary == "Refactor the client runtime")
    #expect(session.branch == "main")
    #expect(session.currentCwd == "/tmp/project")
    #expect(session.repositoryRoot == "/tmp/repo")
    #expect(session.isWorktree)
    #expect(session.unreadCount == 7)
    #expect(session.lastActivityAt == Date(timeIntervalSince1970: 1_234))

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

  @Test func sessionAndObservableApplyTokenUsageKeepSnapshotKindInSync() {
    let usage = ServerTokenUsage(
      inputTokens: 50,
      outputTokens: 25,
      cachedTokens: 10,
      contextWindow: 1_000
    )

    var session = Session(
      id: "session-1",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .none,
      provider: .claude,
      claudeIntegrationMode: .direct
    )
    let observable = SessionObservable(id: "session-1")

    session.applyTokenUsage(usage, snapshotKind: .lifetimeTotals)
    observable.applyTokenUsage(usage, snapshotKind: .lifetimeTotals)

    #expect(session.inputTokens == 50)
    #expect(session.outputTokens == 25)
    #expect(session.cachedTokens == 10)
    #expect(session.contextWindow == 1_000)
    #expect(session.totalTokens == 75)
    #expect(session.tokenUsageSnapshotKind == .lifetimeTotals)

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

    var session = Session(
      id: "session-1",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .none,
      provider: .claude,
      claudeIntegrationMode: .direct
    )
    let observable = SessionObservable(id: "session-1")

    session.applyTurnDiffSnapshot(projection)
    observable.applyTurnDiffSnapshot(projection)

    #expect(session.inputTokens == 40)
    #expect(session.outputTokens == 15)
    #expect(session.cachedTokens == 5)
    #expect(session.contextWindow == 2_000)
    #expect(session.tokenUsageSnapshotKind == .contextTurn)

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

  @Test func sessionAndObservableShareTokenUsageSemantics() {
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

    observable.applySnapshotProjection(SessionDetailSnapshotProjection.from(session))

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
}
