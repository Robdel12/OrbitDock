import Foundation

enum RootSessionListStatus: String, Hashable, Sendable {
  case working
  case permission
  case question
  case reply
  case ended
}

struct RootShellCounts: Equatable, Sendable {
  var total = 0
  var active = 0
  var working = 0
  var attention = 0
  var ready = 0

  nonisolated init(
    total: Int = 0,
    active: Int = 0,
    working: Int = 0,
    attention: Int = 0,
    ready: Int = 0
  ) {
    self.total = total
    self.active = active
    self.working = working
    self.attention = attention
    self.ready = ready
  }
}

struct RootShellEndpointHealth: Identifiable, Equatable, Sendable {
  let endpointId: UUID
  let endpointName: String
  let connectionStatus: ConnectionStatus
  let counts: RootShellCounts

  var id: UUID { endpointId }
}

struct RootSessionNode: Identifiable, Equatable, Sendable {
  let sessionId: String
  let sessionRef: SessionRef
  let endpointName: String?
  let endpointConnectionStatus: ConnectionStatus
  let provider: Provider
  let status: Session.SessionStatus
  let workStatus: Session.WorkStatus
  let attentionReason: Session.AttentionReason
  let listStatus: RootSessionListStatus
  let displayStatus: SessionDisplayStatus
  let title: String
  let titleSortKey: String
  let searchText: String
  let customName: String?
  let contextLine: String?
  let projectPath: String
  let projectName: String?
  let projectKey: String
  let branch: String?
  let model: String?
  let startedAt: Date?
  let lastActivityAt: Date?
  let unreadCount: UInt64
  let pendingToolName: String?
  let repositoryRoot: String?
  let isWorktree: Bool
  let worktreeId: String?
  let codexIntegrationMode: CodexIntegrationMode?
  let claudeIntegrationMode: ClaudeIntegrationMode?
  let effort: String?
  let totalTokens: Int
  let totalCostUSD: Double
  let isActive: Bool
  let showsInMissionControl: Bool
  let needsAttention: Bool
  let isReady: Bool
  let allowsUserNotifications: Bool

  var id: String { sessionRef.scopedID }
  var scopedID: String { sessionRef.scopedID }
  var scopedSessionID: ScopedSessionID { ScopedSessionID(sessionRef: sessionRef) }
  var displayName: String { title }
  var displayTitle: String { title }
  var displayTitleSortKey: String { titleSortKey }
  var normalizedDisplayName: String { titleSortKey }
  var displaySearchText: String { searchText }
  var groupingPath: String { projectKey }
  var hasLiveEndpointConnection: Bool {
    SessionSemantics.hasLiveEndpointConnection(endpointConnectionStatus)
  }
  var hasUnreadMessages: Bool { unreadCount > 0 }
  var isDirectCodex: Bool { provider == .codex && codexIntegrationMode == .direct }
  var isPassiveCodex: Bool { provider == .codex && codexIntegrationMode == .passive }
  var isDirectClaude: Bool { provider == .claude && claudeIntegrationMode == .direct }
  var isDirect: Bool { isDirectCodex || isDirectClaude }
  var formattedDuration: String {
    guard let duration else { return "--" }
    let hours = Int(duration) / 3_600
    let minutes = (Int(duration) % 3_600) / 60
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }
  var duration: TimeInterval? {
    guard let start = startedAt else { return nil }
    let end = isActive ? Date() : (lastActivityAt ?? startedAt)
    guard let end else { return nil }
    return end.timeIntervalSince(start)
  }
  var endedAt: Date? { isActive ? nil : (lastActivityAt ?? startedAt) }
  var lastTool: String? { pendingToolName }
  var endpointId: UUID { sessionRef.endpointId }
}

extension RootSessionNode {
  init(session: Session) {
    let sessionRef = SessionRef(
      endpointId: session.endpointId ?? UUID(),
      sessionId: session.id
    )

    self.init(
      sessionId: session.id,
      sessionRef: sessionRef,
      endpointName: session.endpointName,
      endpointConnectionStatus: session.endpointConnectionStatus ?? .disconnected,
      provider: session.provider,
      status: session.status,
      workStatus: session.workStatus,
      attentionReason: session.attentionReason,
      listStatus: RootSessionNode.listStatus(
        explicit: nil,
        status: session.status,
        attentionReason: session.attentionReason
      ),
      displayStatus: RootSessionNode.displayStatus(
        explicit: nil,
        status: session.status,
        attentionReason: session.attentionReason
      ),
      title: session.displayName,
      titleSortKey: session.normalizedDisplayName,
      searchText: session.displaySearchText,
      customName: session.customName,
      contextLine: RootSessionNode.contextLine(
        summary: session.summary,
        firstPrompt: session.firstPrompt,
        lastMessage: session.lastMessage
      ),
      projectPath: session.projectPath,
      projectName: session.projectName,
      projectKey: session.groupingPath,
      branch: session.branch,
      model: session.model,
      startedAt: session.startedAt,
      lastActivityAt: session.lastActivityAt,
      unreadCount: session.unreadCount,
      pendingToolName: session.pendingToolName,
      repositoryRoot: session.repositoryRoot,
      isWorktree: session.isWorktree,
      worktreeId: session.worktreeId,
      codexIntegrationMode: session.codexIntegrationMode,
      claudeIntegrationMode: session.claudeIntegrationMode,
      effort: session.effort,
      totalTokens: session.totalTokens,
      totalCostUSD: session.totalCostUSD,
      isActive: session.status == .active,
      showsInMissionControl: SessionSemantics.showsInMissionControl(
        status: session.status,
        endpointConnectionStatus: session.endpointConnectionStatus
      ),
      needsAttention: SessionSemantics.needsAttention(
        status: session.status,
        attentionReason: session.attentionReason
      ),
      isReady: SessionSemantics.isReady(
        status: session.status,
        attentionReason: session.attentionReason
      ),
      allowsUserNotifications: !(session.provider == .codex && session.codexIntegrationMode == .passive)
    )
  }

  init(
    session: ServerSessionListItem,
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus
  ) {
    let provider: Provider = switch session.provider {
      case .claude: .claude
      case .codex: .codex
    }

    let status: Session.SessionStatus = session.status == .active ? .active : .ended
    let workStatus = session.workStatus.toSessionWorkStatus()
    let attentionReason = session.workStatus.toAttentionReason()
    let displayStatus = RootSessionNode.displayStatus(
      explicit: session.listStatus,
      status: status,
      attentionReason: attentionReason
    )
    let title = RootSessionNode.displayTitle(
      explicit: session.displayTitle,
      projectName: session.projectName,
      projectPath: session.projectPath
    )
    let trimmedContextLine = session.contextLine?.trimmingCharacters(in: .whitespacesAndNewlines)
    let titleSortKey = RootSessionNode.sortKey(
      explicit: session.displayTitleSortKey,
      title: title
    )
    let searchText = RootSessionNode.searchText(
      explicit: session.displaySearchText,
      title: title,
      contextLine: trimmedContextLine,
      projectName: session.projectName,
      branch: session.gitBranch,
      model: session.model
    )

    self.sessionId = session.id
    self.sessionRef = SessionRef(endpointId: endpointId, sessionId: session.id)
    self.endpointName = endpointName
    self.endpointConnectionStatus = connectionStatus
    self.provider = provider
    self.status = status
    self.workStatus = workStatus
    self.attentionReason = attentionReason
    self.listStatus = RootSessionNode.listStatus(
      explicit: session.listStatus,
      status: status,
      attentionReason: attentionReason
    )
    self.displayStatus = displayStatus
    self.title = title
    self.titleSortKey = titleSortKey
    self.searchText = searchText
    self.customName = nil
    self.contextLine = trimmedContextLine
    self.projectPath = session.projectPath
    self.projectName = session.projectName
    self.projectKey = session.repositoryRoot ?? session.projectPath
    self.branch = session.gitBranch
    self.model = session.model
    self.startedAt = RootSessionNode.parseTimestamp(session.startedAt)
    self.lastActivityAt = RootSessionNode.parseTimestamp(session.lastActivityAt)
    self.unreadCount = session.unreadCount ?? 0
    self.pendingToolName = session.pendingToolName
    self.repositoryRoot = session.repositoryRoot
    self.isWorktree = session.isWorktree ?? false
    self.worktreeId = session.worktreeId
    self.codexIntegrationMode = RootSessionNode.codexMode(provider: session.provider, mode: session.codexIntegrationMode)
    self.claudeIntegrationMode = RootSessionNode.claudeMode(provider: session.provider, mode: session.claudeIntegrationMode)
    self.effort = session.effort
    self.totalTokens = Int(session.totalTokens ?? 0)
    self.totalCostUSD = session.totalCostUSD ?? 0
    self.isActive = status == .active
    self.showsInMissionControl = SessionSemantics.showsInMissionControl(
      status: status,
      endpointConnectionStatus: connectionStatus
    )
    self.needsAttention = SessionSemantics.needsAttention(
      status: status,
      attentionReason: attentionReason
    )
    self.isReady = SessionSemantics.isReady(
      status: status,
      attentionReason: attentionReason
    )
    self.allowsUserNotifications = !(provider == .codex && session.codexIntegrationMode == .passive)
  }

  func withConnectionStatus(_ connectionStatus: ConnectionStatus, endpointName: String?) -> RootSessionNode {
    RootSessionNode(
      sessionId: sessionId,
      sessionRef: sessionRef,
      endpointName: endpointName ?? self.endpointName,
      endpointConnectionStatus: connectionStatus,
      provider: provider,
      status: self.status,
      workStatus: workStatus,
      attentionReason: attentionReason,
      listStatus: listStatus,
      displayStatus: displayStatus,
      title: title,
      titleSortKey: titleSortKey,
      searchText: searchText,
      customName: customName,
      contextLine: contextLine,
      projectPath: projectPath,
      projectName: projectName,
      projectKey: projectKey,
      branch: branch,
      model: model,
      startedAt: startedAt,
      lastActivityAt: lastActivityAt,
      unreadCount: unreadCount,
      pendingToolName: pendingToolName,
      repositoryRoot: repositoryRoot,
      isWorktree: isWorktree,
      worktreeId: worktreeId,
      codexIntegrationMode: codexIntegrationMode,
      claudeIntegrationMode: claudeIntegrationMode,
      effort: effort,
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      isActive: self.status == .active,
      showsInMissionControl: SessionSemantics.showsInMissionControl(
        status: self.status,
        endpointConnectionStatus: connectionStatus
      ),
      needsAttention: needsAttention,
      isReady: isReady,
      allowsUserNotifications: allowsUserNotifications
    )
  }

  func ended(reason _: String) -> RootSessionNode {
    RootSessionNode(
      sessionId: sessionId,
      sessionRef: sessionRef,
      endpointName: endpointName,
      endpointConnectionStatus: endpointConnectionStatus,
      provider: provider,
      status: .ended,
      workStatus: .waiting,
      attentionReason: .none,
      listStatus: .ended,
      displayStatus: .ended,
      title: title,
      titleSortKey: titleSortKey,
      searchText: searchText,
      customName: customName,
      contextLine: contextLine,
      projectPath: projectPath,
      projectName: projectName,
      projectKey: projectKey,
      branch: branch,
      model: model,
      startedAt: startedAt,
      lastActivityAt: lastActivityAt,
      unreadCount: unreadCount,
      pendingToolName: nil,
      repositoryRoot: repositoryRoot,
      isWorktree: isWorktree,
      worktreeId: worktreeId,
      codexIntegrationMode: codexIntegrationMode,
      claudeIntegrationMode: claudeIntegrationMode,
      effort: effort,
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      isActive: false,
      showsInMissionControl: SessionSemantics.showsInMissionControl(
        status: .ended,
        endpointConnectionStatus: endpointConnectionStatus
      ),
      needsAttention: false,
      isReady: false,
      allowsUserNotifications: allowsUserNotifications
    )
  }
}

private enum RootSessionNodeSupport {
  static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}

extension RootSessionNode {
  static func codexMode(provider: ServerProvider, mode: ServerCodexIntegrationMode?) -> CodexIntegrationMode? {
    guard provider == .codex else { return nil }
    return mode?.toSessionMode() ?? .direct
  }

  static func claudeMode(provider: ServerProvider, mode: ServerClaudeIntegrationMode?) -> ClaudeIntegrationMode? {
    guard provider == .claude else { return nil }
    return mode?.toSessionMode()
  }

  static func parseTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    return RootSessionNodeSupport.timestampFormatter.date(from: value)
      ?? ISO8601DateFormatter().date(from: value)
  }

  static func displayTitle(explicit: String?, projectName: String?, projectPath: String) -> String {
    if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
      return explicit
    }
    if let projectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !projectName.isEmpty {
      return projectName
    }
    let lastComponent = URL(fileURLWithPath: projectPath).lastPathComponent
    return lastComponent.isEmpty ? projectPath : lastComponent
  }

  static func sortKey(explicit: String?, title: String) -> String {
    if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
      return explicit
    }
    return title.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
  }

  static func searchText(
    explicit: String?,
    title: String,
    contextLine: String?,
    projectName: String?,
    branch: String?,
    model: String?
  ) -> String {
    if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
      return explicit
    }
    return [title, contextLine, projectName, branch, model]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  static func contextLine(summary: String?, firstPrompt: String?, lastMessage: String?) -> String? {
    [lastMessage, summary, firstPrompt]
      .compactMap { $0?.strippingXMLTags().trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  static func displayStatus(
    explicit: ServerSessionListStatus?,
    status: Session.SessionStatus,
    attentionReason: Session.AttentionReason
  ) -> SessionDisplayStatus {
    if let explicit {
      return switch explicit {
        case .working: .working
        case .permission: .permission
        case .question: .question
        case .reply: .reply
        case .ended: .ended
      }
    }

    if status == .ended { return .ended }
    return switch attentionReason {
      case .awaitingPermission: .permission
      case .awaitingQuestion: .question
      case .awaitingReply: .reply
      case .none: .working
    }
  }

  static func listStatus(
    explicit: ServerSessionListStatus?,
    status: Session.SessionStatus,
    attentionReason: Session.AttentionReason
  ) -> RootSessionListStatus {
    if let explicit {
      return switch explicit {
        case .working: .working
        case .permission: .permission
        case .question: .question
        case .reply: .reply
        case .ended: .ended
      }
    }

    if status == .ended { return .ended }
    return switch attentionReason {
      case .awaitingPermission: .permission
      case .awaitingQuestion: .question
      case .awaitingReply: .reply
      case .none: .working
    }
  }
}
