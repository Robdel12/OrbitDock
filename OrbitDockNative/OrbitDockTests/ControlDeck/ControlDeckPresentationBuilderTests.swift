import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ControlDeckPresentationBuilderTests {
  @Test func workingDirectSessionEntersSteerMode() {
    let presentation = ControlDeckPresentationBuilder.build(
      snapshot: makeSnapshot(
        workStatus: .working,
        acceptsUserInput: true,
        steerable: true,
        canInterrupt: true
      ),
      isLoading: false
    )

    #expect(presentation.activityStatus == .working)
    #expect(presentation.mode == .steer)
    #expect(presentation.headerSubtitle == "Working")
    #expect(presentation.sendTint == "feedbackWarning")
    #expect(presentation.canInterrupt)
    #expect(!presentation.canResume)
  }

  @Test func workingStatusWithoutInterruptCapabilityDoesNotShowStopCapability() {
    let presentation = ControlDeckPresentationBuilder.build(
      snapshot: makeSnapshot(
        workStatus: .working,
        acceptsUserInput: true,
        steerable: true,
        canInterrupt: false
      ),
      isLoading: false
    )

    #expect(presentation.activityStatus == .working)
    #expect(presentation.mode == .steer)
    #expect(!presentation.canInterrupt)
  }

  @Test func pendingPermissionApprovalOverridesReadyStatus() {
    let presentation = ControlDeckPresentationBuilder.build(
      snapshot: makeSnapshot(
        workStatus: .waiting,
        acceptsUserInput: false,
        pendingApproval: makePermissionApproval()
      ),
      isLoading: false
    )

    #expect(presentation.activityStatus == .permission)
    #expect(presentation.mode == .approval)
    #expect(presentation.headerSubtitle == "Awaiting approval")
  }

  @Test func pendingQuestionApprovalUsesQuestionState() {
    let presentation = ControlDeckPresentationBuilder.build(
      snapshot: makeSnapshot(
        workStatus: .waiting,
        acceptsUserInput: false,
        pendingApproval: makeQuestionApproval()
      ),
      isLoading: false
    )

    #expect(presentation.activityStatus == .question)
    #expect(presentation.mode == .approval)
    #expect(presentation.headerSubtitle == "Awaiting answer")
  }

  @Test func openReadySessionUsesComposeMode() {
    let presentation = ControlDeckPresentationBuilder.build(
      snapshot: makeSnapshot(
        workStatus: .waiting,
        acceptsUserInput: true,
        steerable: false
      ),
      isLoading: false
    )

    #expect(presentation.activityStatus == .ready)
    #expect(presentation.mode == .compose)
    #expect(presentation.headerSubtitle == "Ready")
    #expect(presentation.sendTint == "accent")
  }

  @Test func detachedPendingApprovalRequiresResumeInsteadOfApprovalTakeover() {
    let presentation = ControlDeckPresentationBuilder.build(
      snapshot: makeSnapshot(
        lifecycle: .resumable,
        workStatus: .permission,
        acceptsUserInput: false,
        steerable: false,
        connectorAttached: false,
        pendingApproval: makePermissionApproval()
      ),
      isLoading: false
    )

    #expect(presentation.activityStatus == .permission)
    #expect(presentation.mode == .disabled)
    #expect(presentation.canResume)
    #expect(presentation.headerSubtitle == "Session paused")
  }

  @Test func detachedOpenSessionWithoutConnectorCanResume() {
    let presentation = ControlDeckPresentationBuilder.build(
      snapshot: makeSnapshot(
        lifecycle: .open,
        workStatus: .waiting,
        acceptsUserInput: false,
        steerable: false,
        connectorAttached: false
      ),
      isLoading: false
    )

    #expect(presentation.canResume)
    #expect(presentation.mode == .disabled)
  }

  @Test func detachedWorkingSessionDoesNotExposeLiveControls() {
    let presentation = ControlDeckPresentationBuilder.build(
      snapshot: makeSnapshot(
        lifecycle: .open,
        workStatus: .working,
        acceptsUserInput: true,
        steerable: true,
        canInterrupt: true,
        connectorAttached: false
      ),
      isLoading: false
    )

    #expect(presentation.activityStatus == .working)
    #expect(presentation.mode == .disabled)
    #expect(!presentation.canInterrupt)
    #expect(presentation.canResume)
  }

  @Test func rollbackTurnControlsExpandIntoConcreteMenuActions() {
    let presentation = ControlDeckPresentationBuilder.build(
      snapshot: makeSnapshot(
        turnControls: ControlDeckTurnControls(
          undoLastTurn: .init(supported: true, available: true),
          compactContext: .init(supported: true, available: true),
          rollbackTurns: .init(supported: true, available: true),
          maxRollbackTurns: 7
        )
      ),
      isLoading: false
    )

    let turnModule = presentation.statusModules.first { $0.id == .turnControls }
    guard case let .actions(items)? = turnModule?.interaction else {
      Issue.record("Expected turn controls actions module")
      return
    }

    let rollbackActions = items.filter { $0.action.hasPrefix("rollback:") }
    #expect(rollbackActions.map(\.action) == ["rollback:1", "rollback:2", "rollback:5", "rollback:7"])
  }

  private func makeSnapshot(
    lifecycle: ControlDeckLifecycle = .open,
    workStatus: ControlDeckWorkStatus = .waiting,
    acceptsUserInput: Bool = true,
    steerable: Bool = false,
    canInterrupt: Bool = false,
    connectorAttached: Bool = true,
    pendingApproval: ControlDeckApproval? = nil,
    turnControls: ControlDeckTurnControls? = nil
  ) -> ControlDeckSnapshot {
    ControlDeckSnapshot(
      revision: 1,
      sessionId: "session-1",
      state: ControlDeckSessionState(
        provider: .claude,
        controlMode: .direct,
        lifecycle: lifecycle,
        workStatus: workStatus,
        acceptsUserInput: acceptsUserInput,
        steerable: steerable,
        canInterrupt: canInterrupt,
        connectorAttached: connectorAttached,
        projectPath: "/tmp/project",
        currentCwd: "/tmp/project",
        gitBranch: "main",
        config: ControlDeckConfig(
          model: "claude-opus-4",
          effort: "high",
          approvalPolicy: nil,
          approvalPolicyDetails: nil,
          sandboxMode: nil,
          sandboxPolicyDetails: nil,
          approvalsReviewer: nil,
          permissionMode: nil,
          collaborationMode: nil
        )
      ),
      capabilities: ControlDeckCapabilities(
        supportsSkills: true,
        supportsMentions: true,
        supportsImages: true,
        supportsSteer: true,
        allowPerTurnModelOverride: true,
        allowPerTurnEffortOverride: true,
        effortOptions: [],
        approvalModeOptions: [],
        permissionModeOptions: [],
        collaborationModeOptions: [],
        autoReviewOptions: [],
        availableStatusModules: [.turnControls]
      ),
      preferences: ControlDeckPreferences(
        density: .comfortable,
        showWhenEmpty: .auto,
        modules: [
          .init(module: .turnControls, visible: true)
        ]
      ),
      tokenUsage: ControlDeckTokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cachedTokens: 0,
        contextWindow: 0
      ),
      tokenUsageSnapshotKind: .unknown,
      tokenStatus: ControlDeckTokenStatus(label: "—", tone: .muted),
      pendingApproval: pendingApproval,
      sessionShell: nil,
      turnControls: turnControls
    )
  }

  private func makePermissionApproval() -> ControlDeckApproval {
    ControlDeckApproval(
      requestId: "perm-1",
      sessionId: "session-1",
      kind: .permission(.init(reason: "Need filesystem access", groups: [])),
      title: "Permission Request",
      detail: nil,
      riskLevel: .normal,
      riskFindings: [],
      previewType: .action,
      decisionScope: nil,
      proposedAmendment: nil,
      mcpServerName: nil,
      elicitation: nil,
      networkHost: nil,
      networkProtocol: nil
    )
  }

  private func makeQuestionApproval() -> ControlDeckApproval {
    ControlDeckApproval(
      requestId: "question-1",
      sessionId: "session-1",
      kind: .question(prompts: [
        .init(
          id: "prompt-1",
          header: "Question",
          question: "How should we proceed?",
          options: [],
          allowsMultipleSelection: false,
          allowsOther: true,
          isSecret: false
        ),
      ]),
      title: "Question",
      detail: nil,
      riskLevel: .normal,
      riskFindings: [],
      previewType: .prompt,
      decisionScope: nil,
      proposedAmendment: nil,
      mcpServerName: nil,
      elicitation: nil,
      networkHost: nil,
      networkProtocol: nil
    )
  }
}
