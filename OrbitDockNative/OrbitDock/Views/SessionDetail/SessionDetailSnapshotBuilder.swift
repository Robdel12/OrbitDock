import Foundation

enum SessionDetailSnapshotBuilder {
  static func build(
    payload: ServerSessionDetailSnapshotPayload,
    endpointId: UUID,
    sourceServerInstanceId: String?,
    sourceIsRemoteConnection: Bool
  ) -> SessionDetailSnapshot {
    let session = payload.session
    let sessionId = session.id
    let isDirect = session.controlMode == .direct
    let isActive = session.lifecycleState != .ended
    let provider: Provider = session.provider == .codex ? .codex : .claude
    let displayName = resolveDisplayName(session)
    let displayStatus = resolveDisplayStatus(session, isActive: isActive)
    let workStatus = session.workStatus.toSessionWorkStatus()
    let hasGitRepository = session.gitBranch != nil || session.currentCwd != nil || session.isWorktree

    return SessionDetailSnapshot(
      screenPresentation: SessionDetailScreenPresentation(
        displayName: displayName,
        isDirect: isDirect,
        isActive: isActive,
        displayStatus: displayStatus,
        workStatus: workStatus,
        provider: provider,
        model: session.model,
        effort: session.effort,
        endpointName: nil,
        projectPath: session.projectPath,
        issueIdentifier: session.issueIdentifier,
        missionId: session.missionId,
        capabilities: isDirect ? [.direct] : (provider == .codex ? [.passive] : []),
        continuation: SessionContinuation(
          endpointId: endpointId,
          sessionId: sessionId,
          provider: provider,
          displayName: displayName,
          projectPath: session.projectPath,
          model: session.model,
          hasGitRepository: hasGitRepository,
          sourceServerInstanceId: sourceServerInstanceId,
          sourceIsRemoteConnection: sourceIsRemoteConnection
        ),
        debugContext: SessionDetailDebugContext(
          sessionId: sessionId,
          threadId: nil,
          projectPath: session.projectPath,
          provider: provider,
          codexIntegrationMode: session.codexIntegrationMode.map { String(describing: $0) },
          claudeIntegrationMode: session.claudeIntegrationMode.map { String(describing: $0) }
        )
      ),
      usageSource: SessionDetailUsageSource(
        model: session.model,
        inputTokens: Int(session.tokenUsage.inputTokens),
        outputTokens: Int(session.tokenUsage.outputTokens),
        cachedTokens: Int(session.tokenUsage.cachedTokens),
        contextUsed: Int(session.tokenUsage.contextWindow),
        totalTokens: Int(session.tokenUsage.inputTokens + session.tokenUsage.outputTokens)
      ),
      worktreeState: SessionDetailWorktreeState(
        status: mapSessionStatus(session.status),
        isWorktree: session.isWorktree,
        branch: session.gitBranch,
        worktreeId: session.worktreeId,
        projectPath: session.projectPath
      ),
      reviewState: SessionDetailReviewState(
        diff: session.currentDiff,
        cumulativeDiff: session.cumulativeDiff,
        turnDiffs: session.turnDiffs,
        reviewComments: [],
        isDirect: isDirect,
        turnCount: session.turnCount
      ),
      workerState: SessionDetailWorkerState(
        subagents: SessionWorkerRosterPlanner.visibleSubagents(subagents: session.subagents),
        subagentTools: [:],
        subagentMessages: [:],
        agentThreads: [],
        agentThreadPages: [:],
        timelineRevision: 0
      ),
      currentTool: session.pendingToolName,
      lastActivityAt: parseServerTimestamp(session.lastActivityAt),
      footerMode: SessionDetailFooterPlanner.mode(
        controlMode: isDirect ? .direct : .passive,
        lifecycleState: session.lifecycleState
      ),
      sessionStoreEndpointId: endpointId,
      sessionId: sessionId
    )
  }

  private static func resolveDisplayName(_ session: ServerSessionState) -> String {
    SessionSemantics.displayName(
      customName: session.customName,
      summary: session.summary,
      firstPrompt: session.firstPrompt,
      projectName: session.projectName,
      projectPath: session.projectPath
    )
  }

  private static func resolveDisplayStatus(
    _ session: ServerSessionState,
    isActive: Bool
  ) -> SessionDisplayStatus {
    guard isActive else { return .ended }
    if session.pendingApproval != nil {
      switch session.pendingApproval?.type {
      case .permissions: return .permission
      case .question: return .question
      default: return .permission
      }
    }
    switch session.workStatus {
    case .working: return .working
    case .permission: return .permission
    case .question: return .question
    case .waiting, .reply, .ended: return .reply
    }
  }

  private static func mapSessionStatus(_ status: ServerSessionStatus) -> Session.SessionStatus {
    switch status {
    case .active: .active
    case .ended: .ended
    }
  }
}
