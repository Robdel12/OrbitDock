import Foundation
@testable import OrbitDock

let rootShellTestEndpointID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

func makeRootSessionNode(
  from session: Session,
  endpointId: UUID? = nil,
  endpointName: String = "Primary",
  connectionStatus: ConnectionStatus = .connected,
  hasTurnDiff: Bool = false
) -> RootSessionNode {
  let resolvedEndpointID = endpointId ?? session.endpointId ?? rootShellTestEndpointID

  let resolvedWorkStatus = serverWorkStatus(
    from: session.workStatus,
    attentionReason: session.attentionReason
  )
  let resolvedListStatus: ServerSessionListStatus = switch resolvedWorkStatus {
    case .working: .working
    case .waiting: .reply
    case .permission: .permission
    case .question: .question
    case .reply: .reply
    case .ended: .ended
  }

  let listItem = ServerSessionListItem(
    id: session.id,
    provider: session.provider == .codex ? .codex : .claude,
    projectPath: session.projectPath,
    projectName: session.projectName,
    gitBranch: session.branch,
    model: session.model,
    status: session.status == .active ? .active : .ended,
    workStatus: resolvedWorkStatus,
    controlMode: .passive,
    lifecycleState: session.status == .active ? .open : .ended,
    steerable: false,
    codexIntegrationMode: session.codexIntegrationMode.map(serverCodexMode),
    claudeIntegrationMode: session.claudeIntegrationMode.map(serverClaudeMode),
    startedAt: session.startedAt.map(formatServerDate),
    lastActivityAt: session.lastActivityAt.map(formatServerDate),
    unreadCount: session.unreadCount,
    hasTurnDiff: hasTurnDiff,
    pendingToolName: session.pendingToolName,
    repositoryRoot: session.repositoryRoot,
    isWorktree: session.isWorktree,
    worktreeId: session.worktreeId,
    totalTokens: UInt64(max(session.totalTokens, 0)),
    totalCostUSD: session.totalCostUSD,
    inputTokens: UInt64(max(session.inputTokens ?? 0, 0)),
    outputTokens: UInt64(max(session.outputTokens ?? 0, 0)),
    cachedTokens: UInt64(max(session.cachedTokens ?? 0, 0)),
    displayTitle: session.displayName,
    displayTitleSortKey: session.normalizedDisplayName,
    displaySearchText: session.displaySearchText,
    contextLine: session.summary,
    listStatus: resolvedListStatus,
    summaryRevision: 0,
    effort: session.effort,
    activeWorkerCount: 0,
    pendingToolFamily: nil,
    forkedFromSessionId: nil,
    missionId: nil,
    issueIdentifier: nil
  )

  return RootSessionNode(
    session: listItem,
    endpointId: resolvedEndpointID,
    endpointName: session.endpointName ?? endpointName,
    connectionStatus: session.endpointConnectionStatus ?? connectionStatus
  )
}

private func serverWorkStatus(
  from workStatus: Session.WorkStatus,
  attentionReason: Session.AttentionReason
) -> ServerWorkStatus {
  switch attentionReason {
    case .awaitingPermission:
      return .permission
    case .awaitingQuestion:
      return .question
    case .awaitingReply:
      return .reply
    case .none:
      break
  }

  switch workStatus {
    case .working:
      return .working
    case .waiting, .unknown:
      return .waiting
    case .permission:
      return .permission
    case .question:
      return .question
    case .reply:
      return .reply
    case .ended:
      return .ended
  }
}

private func serverCodexMode(_ mode: CodexIntegrationMode) -> ServerCodexIntegrationMode {
  switch mode {
    case .direct:
      .direct
    case .passive:
      .passive
  }
}

private func serverClaudeMode(_ mode: ClaudeIntegrationMode) -> ServerClaudeIntegrationMode {
  switch mode {
    case .direct:
      .direct
    case .passive:
      .passive
  }
}

private func formatServerDate(_ date: Date) -> String {
  date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
}
