import Foundation

private struct RootSessionTimestampCacheEntry: Sendable {
  let date: Date?
}

private final class RootSessionTimestampParser: @unchecked Sendable {
  private let lock = NSLock()
  private var cache: [String: RootSessionTimestampCacheEntry] = [:]
  private let fractionalFormatter: ISO8601DateFormatter
  private let internetDateTimeFormatter: ISO8601DateFormatter

  init() {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.fractionalFormatter = fractionalFormatter

    let internetDateTimeFormatter = ISO8601DateFormatter()
    internetDateTimeFormatter.formatOptions = [.withInternetDateTime]
    self.internetDateTimeFormatter = internetDateTimeFormatter
  }

  func parse(_ rawValue: String) -> Date? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    lock.lock()
    if let cached = cache[trimmed] {
      lock.unlock()
      return cached.date
    }
    lock.unlock()

    let parsedDate = parseUncached(trimmed)

    lock.lock()
    if cache.count >= 4_096 {
      cache.removeAll(keepingCapacity: true)
    }
    cache[trimmed] = RootSessionTimestampCacheEntry(date: parsedDate)
    lock.unlock()

    return parsedDate
  }

  private func parseUncached(_ value: String) -> Date? {
    let unixCandidate = value.hasSuffix("Z") ? String(value.dropLast()) : value
    if let seconds = TimeInterval(unixCandidate) {
      return Date(timeIntervalSince1970: seconds)
    }

    return fractionalFormatter.date(from: value) ?? internetDateTimeFormatter.date(from: value)
  }
}

enum RootSessionStatus: String, Hashable, Sendable {
  case active
  case ended
}

enum RootSessionWorkStatus: String, Hashable, Sendable {
  case working
  case waiting
  case permission
  case unknown
}

enum RootAttentionReason: String, Hashable, Sendable {
  case none
  case awaitingReply
  case awaitingPermission
  case awaitingQuestion
}

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

  var id: UUID {
    endpointId
  }
}

struct RootSessionNode: Identifiable, Sendable {
  let sessionId: String
  let sessionRef: SessionRef
  let endpointName: String?
  let endpointConnectionStatus: ConnectionStatus
  let provider: Provider
  let status: RootSessionStatus
  let workStatus: RootSessionWorkStatus
  let attentionReason: RootAttentionReason
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
  let hasTurnDiff: Bool
  let pendingToolName: String?
  let repositoryRoot: String?
  let isWorktree: Bool
  let worktreeId: String?
  let codexIntegrationMode: CodexIntegrationMode?
  let claudeIntegrationMode: ClaudeIntegrationMode?
  let effort: String?
  let missionId: String?
  let issueIdentifier: String?
  let totalTokens: Int
  let totalCostUSD: Double
  let isActive: Bool
  let showsInMissionControl: Bool
  let needsAttention: Bool
  let isReady: Bool
  let allowsUserNotifications: Bool

  nonisolated var id: String {
    sessionRef.scopedID
  }

  nonisolated var scopedID: String {
    sessionRef.scopedID
  }

  nonisolated var scopedSessionID: ScopedSessionID {
    ScopedSessionID(sessionRef: sessionRef)
  }

  nonisolated var displayName: String {
    title
  }

  nonisolated var displayTitle: String {
    title
  }

  nonisolated var displayTitleSortKey: String {
    titleSortKey
  }

  nonisolated var normalizedDisplayName: String {
    titleSortKey
  }

  nonisolated var displaySearchText: String {
    searchText
  }

  nonisolated var groupingPath: String {
    projectKey
  }

  nonisolated var hasLiveEndpointConnection: Bool {
    RootSessionNode.hasLiveEndpointConnection(endpointConnectionStatus)
  }

  nonisolated var hasUnreadMessages: Bool {
    unreadCount > 0
  }

  nonisolated var isDirectCodex: Bool {
    provider == .codex && codexIntegrationMode == .direct
  }

  nonisolated var isPassiveCodex: Bool {
    provider == .codex && codexIntegrationMode == .passive
  }

  nonisolated var isDirectClaude: Bool {
    provider == .claude && claudeIntegrationMode == .direct
  }

  nonisolated var isDirect: Bool {
    isDirectCodex || isDirectClaude
  }

  nonisolated var formattedDuration: String {
    guard let duration else { return "--" }
    let hours = Int(duration) / 3_600
    let minutes = (Int(duration) % 3_600) / 60
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  nonisolated var duration: TimeInterval? {
    guard let start = startedAt else { return nil }
    let end = isActive ? Date() : (lastActivityAt ?? startedAt)
    guard let end else { return nil }
    return end.timeIntervalSince(start)
  }

  nonisolated var endedAt: Date? {
    isActive ? nil : (lastActivityAt ?? startedAt)
  }

  nonisolated var lastTool: String? {
    pendingToolName
  }

  nonisolated var endpointId: UUID {
    sessionRef.endpointId
  }
}

extension RootSessionNode: Equatable {
  nonisolated static func == (lhs: RootSessionNode, rhs: RootSessionNode) -> Bool {
    lhs.sessionId == rhs.sessionId
      && lhs.sessionRef.endpointId == rhs.sessionRef.endpointId
      && lhs.sessionRef.sessionId == rhs.sessionRef.sessionId
      && lhs.endpointName == rhs.endpointName
      && lhs.endpointConnectionStatus == rhs.endpointConnectionStatus
      && lhs.provider == rhs.provider
      && lhs.status == rhs.status
      && lhs.workStatus == rhs.workStatus
      && lhs.attentionReason == rhs.attentionReason
      && lhs.listStatus == rhs.listStatus
      && lhs.title == rhs.title
      && lhs.titleSortKey == rhs.titleSortKey
      && lhs.searchText == rhs.searchText
      && lhs.customName == rhs.customName
      && lhs.contextLine == rhs.contextLine
      && lhs.projectPath == rhs.projectPath
      && lhs.projectName == rhs.projectName
      && lhs.projectKey == rhs.projectKey
      && lhs.branch == rhs.branch
      && lhs.model == rhs.model
      && lhs.startedAt == rhs.startedAt
      && lhs.lastActivityAt == rhs.lastActivityAt
      && lhs.unreadCount == rhs.unreadCount
      && lhs.hasTurnDiff == rhs.hasTurnDiff
      && lhs.pendingToolName == rhs.pendingToolName
      && lhs.repositoryRoot == rhs.repositoryRoot
      && lhs.isWorktree == rhs.isWorktree
      && lhs.worktreeId == rhs.worktreeId
      && lhs.codexIntegrationMode == rhs.codexIntegrationMode
      && lhs.claudeIntegrationMode == rhs.claudeIntegrationMode
      && lhs.effort == rhs.effort
      && lhs.missionId == rhs.missionId
      && lhs.issueIdentifier == rhs.issueIdentifier
      && lhs.totalTokens == rhs.totalTokens
      && lhs.totalCostUSD == rhs.totalCostUSD
      && lhs.isActive == rhs.isActive
      && lhs.showsInMissionControl == rhs.showsInMissionControl
      && lhs.needsAttention == rhs.needsAttention
      && lhs.isReady == rhs.isReady
      && lhs.allowsUserNotifications == rhs.allowsUserNotifications
  }
}

extension RootSessionNode {
  nonisolated init(
    session: ServerSessionListItem,
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus
  ) {
    let provider: Provider = switch session.provider {
      case .claude: .claude
      case .codex: .codex
    }

    let status: RootSessionStatus = session.status == .active ? .active : .ended
    let workStatus = RootSessionNode.workStatus(from: session.workStatus)
    let attentionReason = RootSessionNode.attentionReason(
      explicitListStatus: session.listStatus,
      fallbackWorkStatus: session.workStatus
    )
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
    self.hasTurnDiff = session.hasTurnDiff ?? false
    self.pendingToolName = session.pendingToolName
    self.repositoryRoot = session.repositoryRoot
    self.isWorktree = session.isWorktree ?? false
    self.worktreeId = session.worktreeId
    self.codexIntegrationMode = RootSessionNode.codexMode(
      provider: session.provider,
      mode: session.codexIntegrationMode
    )
    self.claudeIntegrationMode = RootSessionNode.claudeMode(
      provider: session.provider,
      mode: session.claudeIntegrationMode
    )
    self.effort = session.effort
    self.missionId = session.missionId
    self.issueIdentifier = session.issueIdentifier
    self.totalTokens = Int(session.totalTokens ?? 0)
    self.totalCostUSD = session.totalCostUSD ?? 0
    self.isActive = status == .active
    self.showsInMissionControl = RootSessionNode.showsInMissionControl(
      provider: provider,
      status: status,
      endpointConnectionStatus: connectionStatus,
      codexIntegrationMode: self.codexIntegrationMode,
      claudeIntegrationMode: self.claudeIntegrationMode
    )
    self.needsAttention = RootSessionNode.needsAttention(
      status: status,
      attentionReason: attentionReason
    )
    self.isReady = RootSessionNode.isReady(
      status: status,
      attentionReason: attentionReason
    )
    self.allowsUserNotifications = !(provider == .codex && session.codexIntegrationMode == .passive)
  }

  nonisolated func withConnectionStatus(
    _ connectionStatus: ConnectionStatus,
    endpointName: String?
  ) -> RootSessionNode {
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
      hasTurnDiff: hasTurnDiff,
      pendingToolName: pendingToolName,
      repositoryRoot: repositoryRoot,
      isWorktree: isWorktree,
      worktreeId: worktreeId,
      codexIntegrationMode: codexIntegrationMode,
      claudeIntegrationMode: claudeIntegrationMode,
      effort: effort,
      missionId: missionId,
      issueIdentifier: issueIdentifier,
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      isActive: self.status == .active,
      showsInMissionControl: RootSessionNode.showsInMissionControl(
        provider: provider,
        status: self.status,
        endpointConnectionStatus: connectionStatus,
        codexIntegrationMode: codexIntegrationMode,
        claudeIntegrationMode: claudeIntegrationMode
      ),
      needsAttention: needsAttention,
      isReady: isReady,
      allowsUserNotifications: allowsUserNotifications
    )
  }

  nonisolated func ended(reason _: String) -> RootSessionNode {
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
      hasTurnDiff: hasTurnDiff,
      pendingToolName: nil,
      repositoryRoot: repositoryRoot,
      isWorktree: isWorktree,
      worktreeId: worktreeId,
      codexIntegrationMode: codexIntegrationMode,
      claudeIntegrationMode: claudeIntegrationMode,
      effort: effort,
      missionId: missionId,
      issueIdentifier: issueIdentifier,
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      isActive: false,
      showsInMissionControl: RootSessionNode.showsInMissionControl(
        provider: provider,
        status: .ended,
        endpointConnectionStatus: endpointConnectionStatus,
        codexIntegrationMode: codexIntegrationMode,
        claudeIntegrationMode: claudeIntegrationMode
      ),
      needsAttention: false,
      isReady: false,
      allowsUserNotifications: allowsUserNotifications
    )
  }
}

extension RootSessionNode {
  private nonisolated static let timestampParser = RootSessionTimestampParser()

  nonisolated static func workStatus(from status: ServerWorkStatus) -> RootSessionWorkStatus {
    switch status {
      case .working:
        .working
      case .waiting:
        .waiting
      case .permission:
        .permission
      case .question, .reply, .ended:
        .unknown
    }
  }

  nonisolated static func attentionReason(
    explicitListStatus: ServerSessionListStatus?,
    fallbackWorkStatus status: ServerWorkStatus
  ) -> RootAttentionReason {
    if let explicitListStatus {
      switch explicitListStatus {
        case .permission:
          return .awaitingPermission
        case .question:
          return .awaitingQuestion
        case .reply:
          return .awaitingReply
        case .working, .ended:
          break
      }
    }

    return switch status {
      case .working, .ended:
        .none
      case .waiting, .reply:
        .awaitingReply
      case .permission:
        .awaitingPermission
      case .question:
        .awaitingQuestion
    }
  }

  nonisolated static func hasLiveEndpointConnection(_ status: ConnectionStatus?) -> Bool {
    guard let status else { return true }
    switch status {
      case .connected:
        return true
      case .disconnected, .connecting, .failed:
        return false
    }
  }

  nonisolated static func showsInMissionControl(
    provider: Provider,
    status: RootSessionStatus,
    endpointConnectionStatus: ConnectionStatus?,
    codexIntegrationMode: CodexIntegrationMode?,
    claudeIntegrationMode: ClaudeIntegrationMode?
  ) -> Bool {
    guard status == .active else { return false }
    _ = provider
    _ = endpointConnectionStatus
    _ = codexIntegrationMode
    _ = claudeIntegrationMode
    return true
  }

  nonisolated static func needsAttention(
    status: RootSessionStatus,
    attentionReason: RootAttentionReason
  ) -> Bool {
    status == .active && attentionReason != .none && attentionReason != .awaitingReply
  }

  nonisolated static func isReady(
    status: RootSessionStatus,
    attentionReason: RootAttentionReason
  ) -> Bool {
    status == .active && attentionReason == .awaitingReply
  }

  nonisolated static func codexMode(
    provider: ServerProvider,
    mode: ServerCodexIntegrationMode?
  ) -> CodexIntegrationMode? {
    guard provider == .codex else { return nil }
    return switch mode {
      case .direct?: .direct
      case .passive?: .passive
      case nil: .direct
    }
  }

  nonisolated static func claudeMode(
    provider: ServerProvider,
    mode: ServerClaudeIntegrationMode?
  ) -> ClaudeIntegrationMode? {
    guard provider == .claude else { return nil }
    return switch mode {
      case .direct?: .direct
      case .passive?: .passive
      case nil: nil
    }
  }

  nonisolated static func parseTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    return timestampParser.parse(value)
  }

  nonisolated static func displayTitle(explicit: String?, projectName: String?, projectPath: String) -> String {
    if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
      return explicit
    }
    if let projectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !projectName.isEmpty {
      return projectName
    }
    let lastComponent = URL(fileURLWithPath: projectPath).lastPathComponent
    return lastComponent.isEmpty ? projectPath : lastComponent
  }

  nonisolated static func sortKey(explicit: String?, title: String) -> String {
    if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
      return explicit
    }
    return title.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
  }

  nonisolated static func searchText(
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

  nonisolated static func contextLine(summary: String?, firstPrompt: String?, lastMessage: String?) -> String? {
    [lastMessage, summary, firstPrompt]
      .compactMap { $0?.strippingXMLTags().trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  nonisolated static func displayStatus(
    explicit: ServerSessionListStatus?,
    status: RootSessionStatus,
    attentionReason: RootAttentionReason
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

  nonisolated static func listStatus(
    explicit: ServerSessionListStatus?,
    status: RootSessionStatus,
    attentionReason: RootAttentionReason
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
