import Foundation

struct DashboardConversationRecord: Identifiable, Sendable, Equatable {
  let sessionRef: SessionRef
  let endpointName: String?
  let provider: Provider
  let projectPath: String
  let projectName: String?
  let repositoryRoot: String?
  let branch: String?
  let isWorktree: Bool
  let worktreeId: String?
  let model: String?
  let title: String
  let contextLine: String?
  let lastMessage: String?
  let startedAt: Date?
  let lastActivityAt: Date?
  let unreadCount: UInt64
  let hasTurnDiff: Bool
  let diffPreview: ServerDashboardDiffPreview?
  let pendingToolName: String?
  let pendingToolInput: String?
  let pendingQuestion: String?
  let toolCount: UInt64
  let activeWorkerCount: UInt32
  let issueIdentifier: String?
  let effort: String?
  let listStatus: ServerSessionListStatus
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let claudeIntegrationMode: ServerClaudeIntegrationMode?

  var id: String {
    sessionRef.scopedID
  }

  var sessionId: String {
    sessionRef.sessionId
  }

  var displayStatus: SessionDisplayStatus {
    switch listStatus {
      case .working: .working
      case .permission: .permission
      case .question: .question
      case .reply: .reply
      case .ended: .ended
    }
  }

  var groupingPath: String {
    repositoryRoot ?? projectPath
  }

  var displayProjectName: String {
    projectName ?? URL(fileURLWithPath: projectPath).lastPathComponent
  }

  var isDirect: Bool {
    (provider == .codex && codexIntegrationMode == .direct) || (provider == .claude && claudeIntegrationMode == .direct)
  }

  /// Create an updated copy by applying fields from a SessionListItemUpdated event.
  /// Fields not present in the list item (lastMessage, diffPreview, pendingToolInput,
  /// pendingQuestion, toolCount) are preserved from the existing record.
  func applyingListItemUpdate(_ item: ServerSessionListItem, endpointName: String?) -> DashboardConversationRecord {
    DashboardConversationRecord(
      sessionRef: sessionRef,
      endpointName: endpointName ?? self.endpointName,
      provider: item.provider == .codex ? .codex : .claude,
      projectPath: item.projectPath,
      projectName: item.projectName,
      repositoryRoot: item.repositoryRoot,
      branch: item.gitBranch,
      isWorktree: item.isWorktree ?? self.isWorktree,
      worktreeId: item.worktreeId,
      model: item.model,
      title: item.displayTitle ?? title,
      contextLine: item.contextLine,
      lastMessage: lastMessage,
      startedAt: RootSessionNode.parseTimestamp(item.startedAt) ?? startedAt,
      lastActivityAt: RootSessionNode.parseTimestamp(item.lastActivityAt) ?? lastActivityAt,
      unreadCount: item.unreadCount ?? unreadCount,
      hasTurnDiff: item.hasTurnDiff ?? hasTurnDiff,
      diffPreview: diffPreview,
      pendingToolName: item.pendingToolName,
      pendingToolInput: pendingToolInput,
      pendingQuestion: pendingQuestion,
      toolCount: toolCount,
      activeWorkerCount: UInt32(item.activeWorkerCount ?? UInt64(activeWorkerCount)),
      issueIdentifier: item.issueIdentifier,
      effort: item.effort,
      listStatus: item.listStatus ?? listStatus,
      codexIntegrationMode: item.codexIntegrationMode,
      claudeIntegrationMode: item.claudeIntegrationMode
    )
  }

  private init(
    sessionRef: SessionRef,
    endpointName: String?,
    provider: Provider,
    projectPath: String,
    projectName: String?,
    repositoryRoot: String?,
    branch: String?,
    isWorktree: Bool,
    worktreeId: String?,
    model: String?,
    title: String,
    contextLine: String?,
    lastMessage: String?,
    startedAt: Date?,
    lastActivityAt: Date?,
    unreadCount: UInt64,
    hasTurnDiff: Bool,
    diffPreview: ServerDashboardDiffPreview?,
    pendingToolName: String?,
    pendingToolInput: String?,
    pendingQuestion: String?,
    toolCount: UInt64,
    activeWorkerCount: UInt32,
    issueIdentifier: String?,
    effort: String?,
    listStatus: ServerSessionListStatus,
    codexIntegrationMode: ServerCodexIntegrationMode?,
    claudeIntegrationMode: ServerClaudeIntegrationMode?
  ) {
    self.sessionRef = sessionRef
    self.endpointName = endpointName
    self.provider = provider
    self.projectPath = projectPath
    self.projectName = projectName
    self.repositoryRoot = repositoryRoot
    self.branch = branch
    self.isWorktree = isWorktree
    self.worktreeId = worktreeId
    self.model = model
    self.title = title
    self.contextLine = contextLine
    self.lastMessage = lastMessage
    self.startedAt = startedAt
    self.lastActivityAt = lastActivityAt
    self.unreadCount = unreadCount
    self.hasTurnDiff = hasTurnDiff
    self.diffPreview = diffPreview
    self.pendingToolName = pendingToolName
    self.pendingToolInput = pendingToolInput
    self.pendingQuestion = pendingQuestion
    self.toolCount = toolCount
    self.activeWorkerCount = activeWorkerCount
    self.issueIdentifier = issueIdentifier
    self.effort = effort
    self.listStatus = listStatus
    self.codexIntegrationMode = codexIntegrationMode
    self.claudeIntegrationMode = claudeIntegrationMode
  }

  init(
    item: ServerDashboardConversationItem,
    endpointId: UUID,
    endpointName: String?
  ) {
    self.sessionRef = SessionRef(endpointId: endpointId, sessionId: item.sessionId)
    self.endpointName = endpointName
    self.provider = item.provider == .codex ? .codex : .claude
    self.projectPath = item.projectPath
    self.projectName = item.projectName
    self.repositoryRoot = item.repositoryRoot
    self.branch = item.gitBranch
    self.isWorktree = item.isWorktree
    self.worktreeId = item.worktreeId
    self.model = item.model
    self.title = item.displayTitle
    self.contextLine = item.contextLine
    self.lastMessage = item.lastMessage
    self.startedAt = RootSessionNode.parseTimestamp(item.startedAt)
    self.lastActivityAt = RootSessionNode.parseTimestamp(item.lastActivityAt)
    self.unreadCount = item.unreadCount
    self.hasTurnDiff = item.hasTurnDiff
    self.diffPreview = item.diffPreview
    self.pendingToolName = item.pendingToolName
    self.pendingToolInput = item.pendingToolInput
    self.pendingQuestion = item.pendingQuestion
    self.toolCount = item.toolCount
    self.activeWorkerCount = item.activeWorkerCount
    self.issueIdentifier = item.issueIdentifier
    self.effort = item.effort
    self.listStatus = item.listStatus
    self.codexIntegrationMode = item.codexIntegrationMode
    self.claudeIntegrationMode = item.claudeIntegrationMode
  }
}
