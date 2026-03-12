import Foundation

protocol SessionSummaryItem: Sendable {
  var id: String { get }
  var endpointId: UUID? { get }
  var endpointName: String? { get }
  var endpointConnectionStatus: ConnectionStatus? { get }
  var projectPath: String { get }
  var projectName: String? { get }
  var branch: String? { get }
  var model: String? { get }
  var summary: String? { get }
  var customName: String? { get }
  var firstPrompt: String? { get }
  var lastMessage: String? { get }
  var status: Session.SessionStatus { get }
  var workStatus: Session.WorkStatus { get }
  var startedAt: Date? { get }
  var endedAt: Date? { get }
  var totalTokens: Int { get }
  var totalCostUSD: Double { get }
  var lastActivityAt: Date? { get }
  var lastTool: String? { get }
  var promptCount: Int { get }
  var toolCount: Int { get }
  var attentionReason: Session.AttentionReason { get }
  var pendingToolName: String? { get }
  var provider: Provider { get }
  var codexIntegrationMode: CodexIntegrationMode? { get }
  var claudeIntegrationMode: ClaudeIntegrationMode? { get }
  var inputTokens: Int? { get }
  var outputTokens: Int? { get }
  var cachedTokens: Int? { get }
  var contextWindow: Int? { get }
  var tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind { get }
  var repositoryRoot: String? { get }
  var isWorktree: Bool { get }
  var unreadCount: UInt64 { get }
  var effort: String? { get }
  var scopedID: String { get }
  var sessionRef: SessionRef? { get }
  var displayName: String { get }
  var normalizedDisplayName: String { get }
  var displaySearchText: String { get }
  var groupingPath: String { get }
  var isActive: Bool { get }
  var hasLiveEndpointConnection: Bool { get }
  var showsInMissionControl: Bool { get }
  var hasUnreadMessages: Bool { get }
  var needsAttention: Bool { get }
  var isReady: Bool { get }
  var isDirectCodex: Bool { get }
  var isPassiveCodex: Bool { get }
  var allowsUserNotifications: Bool { get }
  var isDirectClaude: Bool { get }
  var isDirect: Bool { get }
  var effectiveContextInputTokens: Int { get }
  var displayStatus: SessionDisplayStatus { get }
}

extension SessionSummaryItem {
  var scopedID: String {
    guard let endpointId else { return id }
    return SessionRef(endpointId: endpointId, sessionId: id).scopedID
  }

  var sessionRef: SessionRef? {
    guard let endpointId else { return nil }
    return SessionRef(endpointId: endpointId, sessionId: id)
  }

  var displayName: String {
    SessionSemantics.displayName(
      customName: customName,
      summary: summary,
      firstPrompt: firstPrompt,
      projectName: projectName,
      projectPath: projectPath
    )
  }

  var normalizedDisplayName: String {
    displayName.lowercased()
  }

  var displaySearchText: String {
    [
      displayName,
      projectName,
      branch,
      model,
      summary,
      firstPrompt,
      lastMessage,
      projectPath,
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
    .lowercased()
  }

  var groupingPath: String {
    SessionSemantics.groupingPath(repositoryRoot: repositoryRoot, projectPath: projectPath)
  }

  var isActive: Bool {
    status == .active
  }

  var hasLiveEndpointConnection: Bool {
    SessionSemantics.hasLiveEndpointConnection(endpointConnectionStatus)
  }

  var showsInMissionControl: Bool {
    SessionSemantics.showsInMissionControl(status: status, endpointConnectionStatus: endpointConnectionStatus)
  }

  var hasUnreadMessages: Bool {
    unreadCount > 0
  }

  var needsAttention: Bool {
    SessionSemantics.needsAttention(status: status, attentionReason: attentionReason)
  }

  var isReady: Bool {
    SessionSemantics.isReady(status: status, attentionReason: attentionReason)
  }

  var isDirectCodex: Bool {
    provider == .codex && codexIntegrationMode == .direct
  }

  var isPassiveCodex: Bool {
    provider == .codex && codexIntegrationMode == .passive
  }

  var allowsUserNotifications: Bool {
    !isPassiveCodex
  }

  var isDirectClaude: Bool {
    provider == .claude && claudeIntegrationMode == .direct
  }

  var isDirect: Bool {
    isDirectCodex || isDirectClaude
  }

  var effectiveContextInputTokens: Int {
    SessionTokenUsageSemantics.effectiveContextInputTokens(
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      snapshotKind: tokenUsageSnapshotKind,
      provider: provider
    )
  }

  var displayStatus: SessionDisplayStatus {
    guard isActive else { return .ended }

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

  var duration: TimeInterval? {
    guard let start = startedAt else { return nil }
    let end = endedAt ?? Date()
    return end.timeIntervalSince(start)
  }

  var formattedDuration: String {
    guard let duration else { return "--" }
    let hours = Int(duration) / 3_600
    let minutes = (Int(duration) % 3_600) / 60
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }
}

struct SessionSummaryDisplayProjection: Hashable, Sendable {
  let displayName: String
  let normalizedDisplayName: String
  let displaySearchText: String
  let groupingPath: String
  let showsInMissionControl: Bool
  let hasUnreadMessages: Bool
  let needsAttention: Bool
  let isReady: Bool
  let isDirectCodex: Bool
  let isPassiveCodex: Bool
  let allowsUserNotifications: Bool
  let isDirectClaude: Bool
  let isDirect: Bool
  let effectiveContextInputTokens: Int
  let displayStatus: SessionDisplayStatus

  nonisolated static func make(from session: Session) -> SessionSummaryDisplayProjection {
    let displayName = session.displayName
    let normalizedDisplayName = session.normalizedDisplayName
    let displaySearchText = session.displaySearchText

    let groupingPath = SessionSemantics.groupingPath(
      repositoryRoot: session.repositoryRoot,
      projectPath: session.projectPath
    )
    let showsInMissionControl = SessionSemantics.showsInMissionControl(
      status: session.status,
      endpointConnectionStatus: session.endpointConnectionStatus
    )
    let hasUnreadMessages = session.unreadCount > 0
    let needsAttention = SessionSemantics.needsAttention(
      status: session.status,
      attentionReason: session.attentionReason
    )
    let isReady = SessionSemantics.isReady(
      status: session.status,
      attentionReason: session.attentionReason
    )
    let isDirectCodex = session.provider == .codex && session.codexIntegrationMode == .direct
    let isPassiveCodex = session.provider == .codex && session.codexIntegrationMode == .passive
    let allowsUserNotifications = !isPassiveCodex
    let isDirectClaude = session.provider == .claude && session.claudeIntegrationMode == .direct
    let isDirect = isDirectCodex || isDirectClaude
    let effectiveContextInputTokens = SessionTokenUsageSemantics.effectiveContextInputTokens(
      inputTokens: session.inputTokens,
      cachedTokens: session.cachedTokens,
      snapshotKind: session.tokenUsageSnapshotKind,
      provider: session.provider
    )

    let displayStatus: SessionDisplayStatus = {
      guard session.status == .active else { return .ended }
      switch session.attentionReason {
        case .awaitingPermission:
          return .permission
        case .awaitingQuestion:
          return .question
        case .awaitingReply:
          return .reply
        case .none:
          return session.workStatus == .working ? .working : .reply
      }
    }()

    return SessionSummaryDisplayProjection(
      displayName: displayName,
      normalizedDisplayName: normalizedDisplayName,
      displaySearchText: displaySearchText,
      groupingPath: groupingPath,
      showsInMissionControl: showsInMissionControl,
      hasUnreadMessages: hasUnreadMessages,
      needsAttention: needsAttention,
      isReady: isReady,
      isDirectCodex: isDirectCodex,
      isPassiveCodex: isPassiveCodex,
      allowsUserNotifications: allowsUserNotifications,
      isDirectClaude: isDirectClaude,
      isDirect: isDirect,
      effectiveContextInputTokens: effectiveContextInputTokens,
      displayStatus: displayStatus
    )
  }
}

struct SessionSummary: SessionSummaryItem, Identifiable, Hashable, Sendable {
  let id: String
  let endpointId: UUID?
  let endpointName: String?
  let endpointConnectionStatus: ConnectionStatus?
  let projectPath: String
  let projectName: String?
  let branch: String?
  let model: String?
  let summary: String?
  let customName: String?
  let firstPrompt: String?
  let lastMessage: String?
  let status: Session.SessionStatus
  let workStatus: Session.WorkStatus
  let startedAt: Date?
  let endedAt: Date?
  let totalTokens: Int
  let totalCostUSD: Double
  let lastActivityAt: Date?
  let lastTool: String?
  let promptCount: Int
  let toolCount: Int
  let attentionReason: Session.AttentionReason
  let pendingToolName: String?
  let provider: Provider
  let codexIntegrationMode: CodexIntegrationMode?
  let claudeIntegrationMode: ClaudeIntegrationMode?
  let inputTokens: Int?
  let outputTokens: Int?
  let cachedTokens: Int?
  let contextWindow: Int?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind
  let repositoryRoot: String?
  let isWorktree: Bool
  let unreadCount: UInt64
  let effort: String?
  let displayName: String
  let normalizedDisplayName: String
  let displaySearchText: String
  let groupingPath: String
  let showsInMissionControl: Bool
  let hasUnreadMessages: Bool
  let needsAttention: Bool
  let isReady: Bool
  let isDirectCodex: Bool
  let isPassiveCodex: Bool
  let allowsUserNotifications: Bool
  let isDirectClaude: Bool
  let isDirect: Bool
  let effectiveContextInputTokens: Int
  let displayStatus: SessionDisplayStatus

  nonisolated init(session: Session) {
    id = session.id
    endpointId = session.endpointId
    endpointName = session.endpointName
    endpointConnectionStatus = session.endpointConnectionStatus
    projectPath = session.projectPath
    projectName = session.projectName
    branch = session.branch
    model = session.model
    summary = session.summary
    customName = session.customName
    firstPrompt = session.firstPrompt
    lastMessage = session.lastMessage
    status = session.status
    workStatus = session.workStatus
    startedAt = session.startedAt
    endedAt = session.endedAt
    totalTokens = session.totalTokens
    totalCostUSD = session.totalCostUSD
    lastActivityAt = session.lastActivityAt
    lastTool = session.lastTool
    promptCount = session.promptCount
    toolCount = session.toolCount
    attentionReason = session.attentionReason
    pendingToolName = session.pendingToolName
    provider = session.provider
    codexIntegrationMode = session.codexIntegrationMode
    claudeIntegrationMode = session.claudeIntegrationMode
    inputTokens = session.inputTokens
    outputTokens = session.outputTokens
    cachedTokens = session.cachedTokens
    contextWindow = session.contextWindow
    tokenUsageSnapshotKind = session.tokenUsageSnapshotKind
    repositoryRoot = session.repositoryRoot
    isWorktree = session.isWorktree
    unreadCount = session.unreadCount
    effort = session.effort
    let display = SessionSummaryDisplayProjection.make(from: session)
    displayName = display.displayName
    normalizedDisplayName = display.normalizedDisplayName
    displaySearchText = display.displaySearchText
    groupingPath = display.groupingPath
    showsInMissionControl = display.showsInMissionControl
    hasUnreadMessages = display.hasUnreadMessages
    needsAttention = display.needsAttention
    isReady = display.isReady
    isDirectCodex = display.isDirectCodex
    isPassiveCodex = display.isPassiveCodex
    allowsUserNotifications = display.allowsUserNotifications
    isDirectClaude = display.isDirectClaude
    isDirect = display.isDirect
    effectiveContextInputTokens = display.effectiveContextInputTokens
    displayStatus = display.displayStatus
  }
}
