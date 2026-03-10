import Foundation
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

  @Test func modeResolverDoesNotShowTakeoverWithoutPendingApproval() {
    let session = Session(
      id: "session-passive-claude",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingReply,
      provider: .claude,
      claudeIntegrationMode: .passive,
      pendingApprovalId: nil
    )

    let mode = ApprovalCardModeResolver.resolve(
      for: session,
      pendingApprovalId: nil,
      approvalType: nil
    )

    #expect(mode == .none)
  }

  @Test func builderDoesNotTreatHistoryAsLivePendingWithoutAuthoritativeRequestId() {
    let session = makeDirectSession(
      id: "session-approval-history",
      attentionReason: .awaitingPermission,
      pendingApprovalId: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: nil
    )

    #expect(model == nil)
  }

  @Test func builderReadsFromObservablePendingApproval() {
    let sessionId = "session-approval-payload-authoritative"
    let session = makeDirectSession(
      id: sessionId,
      attentionReason: .awaitingPermission,
      pendingApprovalId: "req-1"
    )

    let pendingApproval = ServerApprovalRequest(
      id: "req-1",
      sessionId: sessionId,
      type: .exec
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval
    )

    #expect(model != nil)
    #expect(model?.approvalId == "req-1")
    #expect(model?.approvalType == .exec)
    #expect(model?.mode == .permission)
  }

  @Test func builderEnrichesSparsePendingApprovalFromHistoryForPlanRequests() {
    let sessionId = "session-plan-enrichment"
    let session = Session(
      id: sessionId,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: "Bash",
      pendingToolInput: nil,
      provider: .codex,
      codexIntegrationMode: .direct,
      pendingApprovalId: "req-plan"
    )

    let sparsePendingApproval = ServerApprovalRequest(
      id: "req-plan",
      sessionId: sessionId,
      type: .exec,
      toolName: nil,
      toolInput: nil,
      command: nil,
      filePath: nil,
      diff: nil,
      question: nil,
      preview: nil,
      proposedAmendment: nil
    )

    let history = [
      ServerApprovalHistoryItem(
        id: 1,
        sessionId: sessionId,
        requestId: "req-plan",
        approvalType: .exec,
        toolName: "ExitPlanMode",
        command: nil,
        filePath: nil,
        cwd: nil,
        decision: nil,
        proposedAmendment: nil,
        createdAt: "2026-03-05T22:16:35Z",
        decidedAt: nil
      ),
    ]

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: sparsePendingApproval,
      approvalHistory: history
    )

    #expect(model?.toolName == "ExitPlanMode")
    #expect(model?.previewType == .action)
    #expect(model?.command == "Exit plan mode and begin implementation")
    #expect(model?.approvalType == .exec)
  }

  @Test func builderUsesExitPlanContentFromTranscriptToolInput() {
    let sessionId = "session-plan-content-from-transcript"
    let session = Session(
      id: sessionId,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: "Bash",
      pendingToolInput: nil,
      provider: .claude,
      claudeIntegrationMode: .direct,
      pendingApprovalId: "req-plan-content"
    )

    let pendingApproval = ServerApprovalRequest(
      id: "req-plan-content",
      sessionId: sessionId,
      type: .exec,
      toolName: "ExitPlanMode",
      toolInput: nil,
      command: nil,
      filePath: nil,
      diff: nil,
      question: nil,
      preview: nil,
      proposedAmendment: nil
    )

    let planMarkdown = """
    # Plan
    1. Clarify requirements
    2. Implement change
    """
    let transcript = [
      TranscriptMessage(
        id: "tool-plan",
        type: .tool,
        content: "Exit plan mode",
        timestamp: Date(),
        toolName: "ExitPlanMode",
        toolInput: nil,
        rawToolInput: "{\"plan\":\"# Plan\\n1. Clarify requirements\\n2. Implement change\"}",
        toolOutput: nil,
        toolDuration: nil,
        inputTokens: nil,
        outputTokens: nil,
        isError: false,
        isInProgress: true
      ),
    ]

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval,
      approvalHistory: [],
      transcriptMessages: transcript
    )

    #expect(model?.toolName == "ExitPlanMode")
    #expect(model?.previewType == .prompt)
    #expect(model?.command == planMarkdown)
  }

  @Test func builderUsesExitPlanContentFromHistoryToolInput() {
    let sessionId = "session-plan-content-from-history"
    let session = Session(
      id: sessionId,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: nil,
      pendingToolInput: nil,
      provider: .claude,
      claudeIntegrationMode: .direct,
      pendingApprovalId: "req-plan-history"
    )

    let history = [
      ServerApprovalHistoryItem(
        id: 1,
        sessionId: sessionId,
        requestId: "req-plan-history",
        approvalType: .exec,
        toolName: "ExitPlanMode",
        toolInput: "{\"plan\":\"# Plan\\n1. Ship it\\n2. Verify it\"}",
        command: nil,
        filePath: nil,
        diff: nil,
        question: nil,
        questionPrompts: [],
        preview: nil,
        cwd: nil,
        decision: nil,
        proposedAmendment: nil,
        createdAt: "2026-03-05T22:16:35Z",
        decidedAt: nil
      ),
    ]

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: nil,
      approvalHistory: history,
      transcriptMessages: []
    )

    #expect(model?.toolName == "ExitPlanMode")
    #expect(model?.previewType == .prompt)
    #expect(model?.command == """
    # Plan
    1. Ship it
    2. Verify it
    """)
  }

  @Test func builderIgnoresPendingPayloadWithoutAuthoritativeRequestId() {
    let sessionId = "session-stale-observable"
    let session = Session(
      id: sessionId,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingReply,
      provider: .claude,
      claudeIntegrationMode: .passive,
      pendingApprovalId: nil
    )

    let stalePayload = ServerApprovalRequest(
      id: "req-stale",
      sessionId: sessionId,
      type: .exec,
      toolName: "Bash",
      toolInput: #"{"command":"git status"}"#,
      command: "git status",
      filePath: nil,
      diff: nil,
      question: nil,
      preview: nil,
      proposedAmendment: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: stalePayload
    )

    #expect(model == nil)
  }

  @Test func builderFallsBackToCommandWhenPreviewMissing() {
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
      preview: nil,
      proposedAmendment: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval
    )

    #expect(model?.mode == .permission)
    #expect(model?.command == "xcodebuild -project OrbitDock.xcodeproj -scheme OrbitDock -showdestinations")
    #expect(model?.previewType == .shellCommand)
  }

  @Test func builderFallsBackToSessionPendingToolInputWhenApprovalCommandMissing() {
    let session = Session(
      id: "session-tool-input-fallback",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: "Bash",
      pendingToolInput: "/bin/zsh -lc pwd",
      provider: .codex,
      codexIntegrationMode: .direct,
      pendingApprovalId: "req-fallback"
    )

    let pendingApproval = ServerApprovalRequest(
      id: "req-fallback",
      sessionId: session.id,
      type: .exec,
      toolName: "Bash",
      toolInput: nil,
      command: nil,
      filePath: nil,
      diff: nil,
      question: nil,
      preview: nil,
      proposedAmendment: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval
    )

    #expect(model?.mode == .permission)
    #expect(model?.command == "pwd")
    #expect(model?.previewType == .shellCommand)
  }

  @Test func builderSurfacesRiskFindingsForDestructiveExecCommand() {
    let session = makeDirectSession(
      id: "session-risk-findings",
      attentionReason: .awaitingPermission,
      pendingApprovalId: "req-risk"
    )

    let pendingApproval = ServerApprovalRequest(
      id: "req-risk",
      sessionId: session.id,
      type: .exec,
      toolName: "Bash",
      toolInput: nil,
      command: "sudo rm -rf /tmp/orbitdock-cache",
      filePath: nil,
      diff: nil,
      question: nil,
      preview: ServerApprovalPreview(
        type: .shellCommand,
        value: "sudo rm -rf /tmp/orbitdock-cache",
        shellSegments: [
          ServerApprovalPreviewSegment(command: "sudo rm -rf /tmp/orbitdock-cache", leadingOperator: nil),
        ],
        compact: "sudo rm -rf /tmp/orbitdock-cache",
        decisionScope: "approve/deny applies to all command segments in this request.",
        riskLevel: .high,
        riskFindings: [
          "Uses elevated privileges via sudo.",
          "Deletes files recursively with rm -rf.",
        ],
        manifest: "APPROVAL MANIFEST"
      ),
      proposedAmendment: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval
    )

    #expect(model?.risk == .high)
    #expect(model?.riskFindings.contains("Uses elevated privileges via sudo.") == true)
    #expect(model?.riskFindings.contains("Deletes files recursively with rm -rf.") == true)
  }

  @Test func builderPrefersServerPreviewOverSessionToolInputFallback() {
    let session = Session(
      id: "session-server-preview",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolName: "Bash",
      pendingToolInput: #"{"query":"this should not be used"}"#,
      provider: .codex,
      codexIntegrationMode: .direct,
      pendingApprovalId: "req-preview"
    )

    let pendingApproval = ServerApprovalRequest(
      id: "req-preview",
      sessionId: session.id,
      type: .exec,
      toolName: "Bash",
      toolInput: nil,
      command: nil,
      filePath: nil,
      diff: nil,
      question: nil,
      preview: ServerApprovalPreview(
        type: .shellCommand,
        value: "sqlite3 ~/.orbitdock/orbitdock.db 'SELECT 1' || echo fail",
        shellSegments: [
          ServerApprovalPreviewSegment(
            command: "sqlite3 ~/.orbitdock/orbitdock.db 'SELECT 1'",
            leadingOperator: nil
          ),
          ServerApprovalPreviewSegment(command: "echo fail", leadingOperator: "||"),
        ],
        compact: "sqlite3 ~/.orbitdock/orbitdock.db +1 segment",
        decisionScope: "approve/deny applies to all command segments in this request.",
        riskLevel: .normal,
        riskFindings: [],
        manifest: "APPROVAL MANIFEST\nrequest_id: req-preview"
      ),
      proposedAmendment: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval
    )

    #expect(model?.previewType == .shellCommand)
    #expect(model?.command == "sqlite3 ~/.orbitdock/orbitdock.db 'SELECT 1' || echo fail")
    #expect(model?.shellSegments.count == 2)
    #expect(model?.shellSegments[1].leadingOperator == "||")
    #expect(model?.decisionScope == "approve/deny applies to all command segments in this request.")
    #expect(model?.serverManifest?.contains("APPROVAL MANIFEST") == true)
  }

  @Test func builderUsesServerPreviewTypeForSearchQuery() {
    let session = Session(
      id: "session-search-query",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingPermission,
      pendingToolInput: #"{"query":"swift sqlite migration patterns"}"#,
      provider: .claude,
      claudeIntegrationMode: .direct,
      pendingApprovalId: "req-search"
    )

    let pendingApproval = ServerApprovalRequest(
      id: "req-search",
      sessionId: session.id,
      type: .exec,
      toolName: "WebSearch",
      toolInput: nil,
      command: nil,
      filePath: nil,
      diff: nil,
      question: nil,
      preview: ServerApprovalPreview(
        type: .searchQuery,
        value: "swift sqlite migration patterns",
        shellSegments: [],
        compact: "query: swift sqlite migration patterns",
        decisionScope: "approve/deny applies to this full tool action.",
        riskLevel: .normal,
        riskFindings: [],
        manifest: "APPROVAL MANIFEST"
      ),
      proposedAmendment: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval
    )

    #expect(model?.mode == .permission)
    #expect(model?.command == "swift sqlite migration patterns")
    #expect(model?.previewType == .searchQuery)
  }

  @Test func builderUsesServerQuestionPrompts() {
    let session = Session(
      id: "session-question-options",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingQuestion,
      provider: .claude,
      claudeIntegrationMode: .direct,
      pendingApprovalId: "req-question"
    )

    let pendingApproval = ServerApprovalRequest(
      id: "req-question",
      sessionId: session.id,
      type: .question,
      toolName: "AskUserQuestion",
      toolInput: nil,
      command: nil,
      filePath: nil,
      diff: nil,
      question: "How do you want to launch?",
      questionPrompts: [
        ServerApprovalQuestionPrompt(
          id: "speed",
          header: "Speed",
          question: "How do you want to launch?",
          options: [
            ServerApprovalQuestionOption(label: "Open Sheet", description: "Open full sheet first"),
            ServerApprovalQuestionOption(label: "Quick Launch", description: "Use defaults immediately"),
          ]
        ),
      ],
      preview: nil,
      proposedAmendment: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval
    )

    #expect(model?.mode == .question)
    #expect(model?.questions.first?.id == "speed")
    #expect(model?.questions.first?.question == "How do you want to launch?")
    #expect(model?.questions.first?.options.count == 2)
    #expect(model?.questions.first?.options.first?.label == "Open Sheet")
  }

  @Test func builderUsesMultipleServerQuestionPrompts() {
    let session = Session(
      id: "session-multi-question-options",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .permission,
      attentionReason: .awaitingQuestion,
      provider: .claude,
      claudeIntegrationMode: .direct,
      pendingApprovalId: "req-question"
    )

    let pendingApproval = ServerApprovalRequest(
      id: "req-question",
      sessionId: session.id,
      type: .question,
      toolName: "AskUserQuestion",
      toolInput: nil,
      command: nil,
      filePath: nil,
      diff: nil,
      question: "How do you want to launch?",
      questionPrompts: [
        ServerApprovalQuestionPrompt(
          id: "speed",
          header: "Speed",
          question: "How do you want to launch?",
          options: [
            ServerApprovalQuestionOption(label: "Open Sheet", description: "Open full sheet first"),
            ServerApprovalQuestionOption(label: "Quick Launch", description: "Use defaults immediately"),
          ]
        ),
        ServerApprovalQuestionPrompt(
          id: "confirm",
          header: "Confirm",
          question: "Apply this setup?",
          options: [],
          allowsMultipleSelection: true,
          allowsOther: true,
          isSecret: false
        ),
      ],
      preview: nil,
      proposedAmendment: nil
    )

    let model = ApprovalCardModelBuilder.build(
      session: session,
      pendingApproval: pendingApproval
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
