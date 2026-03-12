import SwiftUI

#Preview {
  ZStack {
    Color.black.opacity(0.5)
      .ignoresSafeArea()

    QuickSwitcher(
      onQuickLaunchClaude: nil,
      onQuickLaunchCodex: nil
    )
    .environment(AppRouter())
    .environment(quickSwitcherPreviewRootShellStore())
  }
  .frame(width: 800, height: 600)
}

private func quickSwitcherPreviewNode(
  id: String,
  projectPath: String,
  projectName: String,
  branch: String?,
  model: String?,
  contextLine: String?,
  status: RootSessionStatus,
  workStatus: RootSessionWorkStatus,
  startedAt: Date,
  endedAt: Date? = nil
) -> RootSessionNode {
  let attentionReason: RootAttentionReason = switch workStatus {
    case .permission: .awaitingPermission
    case .waiting: .awaitingReply
    default: .none
  }
  let listStatus: RootSessionListStatus = switch (status, attentionReason) {
    case (.ended, _):
      .ended
    case (_, .awaitingPermission):
      .permission
    case (_, .awaitingQuestion):
      .question
    case (.active, _):
      workStatus == .working ? .working : .reply
    default:
      .ended
  }
  let displayStatus: SessionDisplayStatus = switch listStatus {
    case .working: .working
    case .permission: .permission
    case .question: .question
    case .reply: .reply
    case .ended: .ended
  }
  return RootSessionNode(
    sessionId: id,
    sessionRef: SessionRef(endpointId: UUID(), sessionId: id),
    endpointName: "Local",
    endpointConnectionStatus: .connected,
    provider: .claude,
    status: status,
    workStatus: workStatus,
    attentionReason: attentionReason,
    listStatus: listStatus,
    displayStatus: displayStatus,
    title: projectName,
    titleSortKey: projectName.lowercased(),
    searchText: [projectName, branch, model, contextLine].compactMap { $0 }.joined(separator: " "),
    customName: nil,
    contextLine: contextLine,
    projectPath: projectPath,
    projectName: projectName,
    projectKey: projectPath,
    branch: branch,
    model: model,
    startedAt: startedAt,
    lastActivityAt: endedAt ?? startedAt,
    unreadCount: 0,
    hasTurnDiff: false,
    pendingToolName: nil,
    repositoryRoot: nil,
    isWorktree: false,
    worktreeId: nil,
    codexIntegrationMode: nil,
    claudeIntegrationMode: .direct,
    effort: nil,
    totalTokens: 0,
    totalCostUSD: 0,
    isActive: status == .active,
    showsInMissionControl: status == .active,
    needsAttention: displayStatus.needsAttention,
    isReady: displayStatus == .reply,
    allowsUserNotifications: true
  )
}

private func quickSwitcherPreviewRootShellStore() -> RootShellStore {
  let store = RootShellStore()
  store.apply(.seed(
    endpointId: UUID(),
    records: [
      quickSwitcherPreviewNode(
        id: "1",
        projectPath: "/Users/developer/Developer/vizzly-cli",
        projectName: "vizzly-cli",
        branch: "feat/auth",
        model: "claude-opus-4-5-20251101",
        contextLine: "Auth refactor",
        status: .active,
        workStatus: .working,
        startedAt: Date()
      ),
      quickSwitcherPreviewNode(
        id: "2",
        projectPath: "/Users/developer/Developer/backchannel",
        projectName: "backchannel",
        branch: "main",
        model: "claude-sonnet-4-20250514",
        contextLine: "API review",
        status: .active,
        workStatus: .waiting,
        startedAt: Date()
      ),
      quickSwitcherPreviewNode(
        id: "3",
        projectPath: "/Users/developer/Developer/docs",
        projectName: "docs",
        branch: "main",
        model: "claude-haiku-3-5-20241022",
        contextLine: nil,
        status: .ended,
        workStatus: .unknown,
        startedAt: Date().addingTimeInterval(-7_200),
        endedAt: Date().addingTimeInterval(-3_600)
      ),
    ]
  ))
  return store
}
