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

  let listItem = ServerSessionListItem(
    id: session.id,
    provider: session.provider == .codex ? .codex : .claude,
    projectPath: session.projectPath,
    projectName: session.projectName,
    gitBranch: session.branch,
    model: session.model,
    status: session.status == .active ? .active : .ended,
    workStatus: serverWorkStatus(
      from: session.workStatus,
      attentionReason: session.attentionReason
    ),
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
    displayTitle: session.displayName,
    displayTitleSortKey: session.normalizedDisplayName,
    displaySearchText: session.displaySearchText,
    contextLine: session.summary,
    listStatus: nil,
    effort: session.effort
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
  }
}

private func serverCodexMode(_ mode: CodexIntegrationMode) -> ServerCodexIntegrationMode {
  switch mode {
    case .direct:
      return .direct
    case .passive:
      return .passive
  }
}

private func serverClaudeMode(_ mode: ClaudeIntegrationMode) -> ServerClaudeIntegrationMode {
  switch mode {
    case .direct:
      return .direct
    case .passive:
      return .passive
  }
}

private func formatServerDate(_ date: Date) -> String {
  date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
}
