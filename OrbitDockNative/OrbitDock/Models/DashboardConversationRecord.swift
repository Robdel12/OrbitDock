import Foundation

enum DashboardConversationIntegrationMode: String, Sendable, Equatable {
  case direct
  case passive
}

struct DashboardConversationRecord: Identifiable, Sendable, Equatable {
  let sessionRef: SessionRef
  let endpointName: String?
  let provider: Provider
  let projectPath: String
  let serverGroupingPath: String?
  let serverGroupingName: String?
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
  let status: ServerSessionStatus
  let workStatus: ServerWorkStatus
  let listStatus: ServerSessionListStatus
  let codexIntegrationMode: ServerCodexIntegrationMode?
  let claudeIntegrationMode: ServerClaudeIntegrationMode?
  let compactPreviewText: String
  let activitySummaryText: String
  let alertContextText: String
  let compactBranchLabel: String?
  let expandedBranchLabel: String?
  let modelDisplayLabel: String?

  nonisolated var id: String {
    sessionRef.scopedID
  }

  nonisolated var sessionId: String {
    sessionRef.sessionId
  }

  nonisolated var displayStatus: SessionDisplayStatus {
    Self.resolveDisplayStatus(
      status: status,
      workStatus: workStatus,
      listStatus: listStatus
    )
  }

  nonisolated var groupingPath: String {
    serverGroupingPath ?? repositoryRoot ?? projectPath
  }

  nonisolated var displayProjectName: String {
    projectName ?? serverGroupingName ?? URL(fileURLWithPath: groupingPath).lastPathComponent
  }

  nonisolated var isDirect: Bool {
    (provider == .codex && codexIntegrationMode == .direct) || (provider == .claude && claudeIntegrationMode == .direct)
  }

  nonisolated var integrationMode: DashboardConversationIntegrationMode? {
    switch provider {
      case .codex:
        switch codexIntegrationMode {
          case .direct?: .direct
          case .passive?: .passive
          case nil: nil
        }
      case .claude:
        switch claudeIntegrationMode ?? .passive {
          case .direct: .direct
          case .passive: .passive
        }
    }
  }

  nonisolated var isPassive: Bool {
    integrationMode == .passive
  }

  nonisolated var canEnd: Bool {
    status == .active
  }

  /// Create an updated copy by applying fields from a SessionListItemUpdated event.
  /// Fields not present in the list item (lastMessage, diffPreview, pendingToolInput,
  /// pendingQuestion, toolCount) are preserved from the existing record.
  func applyingListItemUpdate(_ item: ServerSessionListItem, endpointName: String?) -> DashboardConversationRecord {
    let updatedGroupingPath = item.repositoryRoot ?? item.projectPath
    let updatedGroupingName =
      item.projectName ?? URL(fileURLWithPath: updatedGroupingPath).lastPathComponent

    return DashboardConversationRecord(
      sessionRef: sessionRef,
      endpointName: endpointName ?? self.endpointName,
      provider: item.provider == .codex ? .codex : .claude,
      projectPath: item.projectPath,
      serverGroupingPath: updatedGroupingPath,
      serverGroupingName: updatedGroupingName,
      projectName: item.projectName,
      repositoryRoot: item.repositoryRoot,
      branch: item.gitBranch,
      isWorktree: item.isWorktree,
      worktreeId: item.worktreeId,
      model: item.model,
      title: item.displayTitle,
      contextLine: item.contextLine,
      lastMessage: lastMessage,
      startedAt: RootSessionNode.parseTimestamp(item.startedAt) ?? startedAt,
      lastActivityAt: RootSessionNode.parseTimestamp(item.lastActivityAt) ?? lastActivityAt,
      unreadCount: item.unreadCount,
      hasTurnDiff: item.hasTurnDiff,
      diffPreview: diffPreview,
      pendingToolName: item.pendingToolName,
      pendingToolInput: pendingToolInput,
      pendingQuestion: pendingQuestion,
      toolCount: toolCount,
      activeWorkerCount: UInt32(item.activeWorkerCount),
      issueIdentifier: item.issueIdentifier,
      effort: item.effort,
      status: item.status,
      workStatus: item.workStatus,
      listStatus: item.listStatus,
      codexIntegrationMode: item.codexIntegrationMode,
      claudeIntegrationMode: item.claudeIntegrationMode,
      compactPreviewText: Self.makeCompactPreviewText(
        serverValue: compactPreviewText,
        lastMessage: lastMessage,
        contextLine: item.contextLine
      ),
      activitySummaryText: Self.makeActivitySummaryText(
        serverValue: activitySummaryText,
        pendingToolName: item.pendingToolName,
        lastMessage: lastMessage,
        contextLine: item.contextLine
      ),
      alertContextText: Self.makeAlertContextText(
        serverValue: alertContextText,
        pendingQuestion: pendingQuestion,
        pendingToolName: item.pendingToolName,
        pendingToolInput: pendingToolInput,
        lastMessage: lastMessage,
        contextLine: item.contextLine
      ),
      compactBranchLabel: Self.makeBranchLabel(item.gitBranch, max: 16),
      expandedBranchLabel: Self.makeBranchLabel(item.gitBranch, max: 20),
      modelDisplayLabel: displayNameForModel(item.model, provider: item.provider == .codex ? .codex : .claude)
    )
  }

  private init(
    sessionRef: SessionRef,
    endpointName: String?,
    provider: Provider,
    projectPath: String,
    serverGroupingPath: String?,
    serverGroupingName: String?,
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
    status: ServerSessionStatus,
    workStatus: ServerWorkStatus,
    listStatus: ServerSessionListStatus,
    codexIntegrationMode: ServerCodexIntegrationMode?,
    claudeIntegrationMode: ServerClaudeIntegrationMode?,
    compactPreviewText: String,
    activitySummaryText: String,
    alertContextText: String,
    compactBranchLabel: String?,
    expandedBranchLabel: String?,
    modelDisplayLabel: String?
  ) {
    self.sessionRef = sessionRef
    self.endpointName = endpointName
    self.provider = provider
    self.projectPath = projectPath
    self.serverGroupingPath = serverGroupingPath
    self.serverGroupingName = serverGroupingName
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
    self.status = status
    self.workStatus = workStatus
    self.listStatus = listStatus
    self.codexIntegrationMode = codexIntegrationMode
    self.claudeIntegrationMode = claudeIntegrationMode
    self.compactPreviewText = compactPreviewText
    self.activitySummaryText = activitySummaryText
    self.alertContextText = alertContextText
    self.compactBranchLabel = compactBranchLabel
    self.expandedBranchLabel = expandedBranchLabel
    self.modelDisplayLabel = modelDisplayLabel
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
    self.serverGroupingPath = item.groupingPath
    self.serverGroupingName = item.groupingName
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
    self.status = item.status
    self.workStatus = item.workStatus
    self.listStatus = item.listStatus
    self.codexIntegrationMode = item.codexIntegrationMode
    self.claudeIntegrationMode = item.claudeIntegrationMode
    self.compactPreviewText = Self.makeCompactPreviewText(
      serverValue: item.previewText,
      lastMessage: item.lastMessage,
      contextLine: item.contextLine
    )
    self.activitySummaryText = Self.makeActivitySummaryText(
      serverValue: item.activitySummary,
      pendingToolName: item.pendingToolName,
      lastMessage: item.lastMessage,
      contextLine: item.contextLine
    )
    self.alertContextText = Self.makeAlertContextText(
      serverValue: item.alertContext,
      pendingQuestion: item.pendingQuestion,
      pendingToolName: item.pendingToolName,
      pendingToolInput: item.pendingToolInput,
      lastMessage: item.lastMessage,
      contextLine: item.contextLine
    )
    self.compactBranchLabel = Self.makeBranchLabel(item.gitBranch, max: 16)
    self.expandedBranchLabel = Self.makeBranchLabel(item.gitBranch, max: 20)
    self.modelDisplayLabel = displayNameForModel(self.model, provider: self.provider)
  }
}

private extension DashboardConversationRecord {
  nonisolated static func resolveDisplayStatus(
    status: ServerSessionStatus,
    workStatus: ServerWorkStatus,
    listStatus: ServerSessionListStatus
  ) -> SessionDisplayStatus {
    guard status == .active else { return .ended }

    switch workStatus {
      case .permission:
        return .permission
      case .question:
        return .question
      case .working:
        return .working
      case .waiting, .reply:
        break
      case .ended:
        break
    }

    switch listStatus {
      case .permission: return .permission
      case .question: return .question
      case .working: return .working
      case .reply, .ended: return .reply
    }
  }

  static func makeCompactPreviewText(
    serverValue: String? = nil,
    lastMessage: String?,
    contextLine: String?
  ) -> String {
    if let serverValue, !serverValue.isEmpty {
      return serverValue
    }
    return cleanMarkdown(lastMessage ?? contextLine ?? "Waiting for your next message.")
  }

  static func makeActivitySummaryText(
    serverValue: String? = nil,
    pendingToolName: String?,
    lastMessage: String?,
    contextLine: String?
  ) -> String {
    if let serverValue, !serverValue.isEmpty {
      return serverValue
    }
    if let pendingToolName {
      return "Running \(pendingToolName)"
    }
    return cleanMarkdown(lastMessage ?? contextLine ?? "Processing…")
  }

  static func makeAlertContextText(
    serverValue: String? = nil,
    pendingQuestion: String?,
    pendingToolName: String?,
    pendingToolInput: String?,
    lastMessage: String?,
    contextLine: String?
  ) -> String {
    if let serverValue, !serverValue.isEmpty {
      return serverValue
    }
    if let pendingQuestion, !pendingQuestion.isEmpty {
      return pendingQuestion
    }
    if let pendingToolName {
      return formatToolContext(toolName: pendingToolName, input: pendingToolInput)
    }
    return cleanMarkdown(lastMessage ?? contextLine ?? "Needs your attention.")
  }

  static func makeBranchLabel(_ branch: String?, max: Int) -> String? {
    guard let branch, !branch.isEmpty else { return nil }
    if branch.count <= max { return branch }
    return "\(branch.prefix(max - 1))…"
  }

  static func cleanMarkdown(_ text: String) -> String {
    text
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "__", with: "")
      .replacingOccurrences(of: "`", with: "")
      .replacingOccurrences(of: "## ", with: "")
      .replacingOccurrences(of: "# ", with: "")
  }

  static func formatToolContext(toolName: String, input: String?) -> String {
    guard let input, !input.isEmpty,
          let data = input.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return "Wants to run \(toolName)"
    }

    switch toolName {
      case "Bash":
        if let command = json["command"] as? String {
          return command
        }
      case "Edit":
        if let path = json["file_path"] as? String {
          return "Edit \(URL(fileURLWithPath: path).lastPathComponent)"
        }
      case "Write":
        if let path = json["file_path"] as? String {
          return "Write \(URL(fileURLWithPath: path).lastPathComponent)"
        }
      case "Read":
        if let path = json["file_path"] as? String {
          return "Read \(URL(fileURLWithPath: path).lastPathComponent)"
        }
      case "Grep":
        if let pattern = json["pattern"] as? String {
          return "Search for \"\(pattern)\""
        }
      case "Glob":
        if let pattern = json["pattern"] as? String {
          return "Find files matching \(pattern)"
        }
      default:
        break
    }

    return "Wants to run \(toolName)"
  }
}
