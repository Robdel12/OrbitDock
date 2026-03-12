import Foundation

enum RootSessionListStatus: String, Hashable, Sendable {
  case working
  case permission
  case question
  case reply
  case ended
}

struct RootSessionRecord: Identifiable, Hashable, Sendable, SessionSummaryItem {
  let sessionId: String
  let endpointId: UUID?
  let endpointName: String?
  let endpointConnectionStatus: ConnectionStatus?
  let provider: Provider
  let status: Session.SessionStatus
  let workStatus: Session.WorkStatus
  let attentionReason: Session.AttentionReason
  let listStatus: RootSessionListStatus
  let summary: String?
  let customName: String?
  let firstPrompt: String?
  let lastMessage: String?
  let displayTitle: String
  let displayTitleSortKey: String
  let displaySearchText: String
  let contextLine: String?
  let projectPath: String
  let projectName: String?
  let branch: String?
  let model: String?
  let startedAt: Date?
  let lastActivityAt: Date?
  let endedAt: Date?
  let unreadCount: UInt64
  let repositoryRoot: String?
  let isWorktree: Bool
  let worktreeId: String?
  let codexIntegrationMode: CodexIntegrationMode?
  let claudeIntegrationMode: ClaudeIntegrationMode?
  let effort: String?
  let pendingToolName: String?
  let pendingQuestion: String?
  let lastTool: String?
  let totalTokens: Int
  let totalCostUSD: Double
  let isActive: Bool
  let showsInMissionControl: Bool
  let needsAttention: Bool
  let isReady: Bool
  let allowsUserNotifications: Bool

  var id: String {
    scopedID
  }

  var transcriptPath: String? { nil }
  var promptCount: Int { 0 }
  var toolCount: Int { 0 }
  var inputTokens: Int? { nil }
  var outputTokens: Int? { nil }
  var cachedTokens: Int? { nil }
  var contextWindow: Int? { nil }
  var tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind { .unknown }
  var displayName: String { displayTitle }
  var normalizedDisplayName: String { displayTitleSortKey }
  var groupingPath: String { repositoryRoot ?? projectPath }
  var hasLiveEndpointConnection: Bool {
    SessionSemantics.hasLiveEndpointConnection(endpointConnectionStatus)
  }
  var hasUnreadMessages: Bool { unreadCount > 0 }
  var isDirectCodex: Bool { provider == .codex && codexIntegrationMode == .direct }
  var isPassiveCodex: Bool { provider == .codex && codexIntegrationMode == .passive }
  var isDirectClaude: Bool { provider == .claude && claudeIntegrationMode == .direct }
  var isDirect: Bool { isDirectCodex || isDirectClaude }
  var effectiveContextInputTokens: Int { 0 }

  var displayStatus: SessionDisplayStatus {
    switch listStatus {
      case .working:
        return .working
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

  var scopedID: String {
    sessionRef?.scopedID ?? sessionId
  }

  var sessionRef: SessionRef? {
    guard let endpointId else { return nil }
    return SessionRef(endpointId: endpointId, sessionId: sessionId)
  }
}

enum RootSessionRecordSemantics {
  nonisolated static func displayTitle(
    customName: String?,
    summary: String?,
    firstPrompt: String?,
    projectName: String?,
    projectPath: String
  ) -> String {
    SessionSemantics.displayName(
      customName: customName,
      summary: summary,
      firstPrompt: firstPrompt,
      projectName: projectName,
      projectPath: projectPath
    )
  }

  nonisolated static func sortKey(for displayTitle: String) -> String {
    displayTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  nonisolated static func searchText(
    displayTitle: String,
    contextLine: String?,
    projectName: String?,
    branch: String?,
    model: String?
  ) -> String {
    [
      displayTitle,
      contextLine,
      projectName,
      branch,
      model,
    ]
    .compactMap { value -> String? in
      guard let value else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    .joined(separator: " ")
  }

  nonisolated static func contextLine(summary: String?, firstPrompt: String?, lastMessage: String?) -> String? {
    [
      lastMessage,
      summary,
      firstPrompt,
    ]
    .compactMap { value -> String? in
      guard let value else { return nil }
      let cleaned = value.strippingXMLTags().trimmingCharacters(in: .whitespacesAndNewlines)
      return cleaned.isEmpty ? nil : cleaned
    }
    .first
  }

  nonisolated static func listStatus(
    status: Session.SessionStatus,
    workStatus: Session.WorkStatus,
    attentionReason: Session.AttentionReason
  ) -> RootSessionListStatus {
    guard status == .active else { return .ended }

    switch attentionReason {
      case .awaitingPermission:
        return .permission
      case .awaitingQuestion:
        return .question
      case .awaitingReply:
        return .reply
      case .none:
        return workStatus == .working ? .working : .reply
    }
  }
}

extension RootSessionRecord {
  nonisolated init(summary: SessionSummary) {
    let attentionReason = summary.attentionReason
    let isActive = summary.status == .active
    let needsAttention = SessionSemantics.needsAttention(
      status: summary.status,
      attentionReason: attentionReason
    )
    let isReady = SessionSemantics.isReady(
      status: summary.status,
      attentionReason: attentionReason
    )
    self.init(
      sessionId: summary.id,
      endpointId: summary.endpointId,
      endpointName: summary.endpointName,
      endpointConnectionStatus: summary.endpointConnectionStatus,
      provider: summary.provider,
      status: summary.status,
      workStatus: summary.workStatus,
      attentionReason: attentionReason,
      listStatus: RootSessionRecordSemantics.listStatus(
        status: summary.status,
        workStatus: summary.workStatus,
        attentionReason: attentionReason
      ),
      summary: summary.summary,
      customName: summary.customName,
      firstPrompt: summary.firstPrompt,
      lastMessage: summary.lastMessage,
      displayTitle: summary.displayName,
      displayTitleSortKey: summary.normalizedDisplayName,
      displaySearchText: summary.displaySearchText,
      contextLine: RootSessionRecordSemantics.contextLine(
        summary: summary.summary,
        firstPrompt: summary.firstPrompt,
        lastMessage: summary.lastMessage
      ),
      projectPath: summary.projectPath,
      projectName: summary.projectName,
      branch: summary.branch,
      model: summary.model,
      startedAt: summary.startedAt,
      lastActivityAt: summary.lastActivityAt,
      endedAt: summary.endedAt,
      unreadCount: summary.unreadCount,
      repositoryRoot: summary.repositoryRoot,
      isWorktree: summary.isWorktree,
      worktreeId: nil,
      codexIntegrationMode: summary.codexIntegrationMode,
      claudeIntegrationMode: summary.claudeIntegrationMode,
      effort: summary.effort,
      pendingToolName: summary.pendingToolName,
      pendingQuestion: nil,
      lastTool: summary.lastTool,
      totalTokens: summary.totalTokens,
      totalCostUSD: summary.totalCostUSD,
      isActive: isActive,
      showsInMissionControl: summary.showsInMissionControl,
      needsAttention: needsAttention,
      isReady: isReady,
      allowsUserNotifications: summary.allowsUserNotifications
    )
  }
}
