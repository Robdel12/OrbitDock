import Foundation

struct SessionStateProjection {
  let status: Session.SessionStatus?
  let workStatus: Session.WorkStatus?
  let attentionReason: Session.AttentionReason?
  let tokenUsage: ServerTokenUsage?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind?
  let currentDiff: String??
  let plan: String??
  let customName: String??
  let summary: String??
  let firstPrompt: String??
  let lastMessage: String??
  let codexIntegrationMode: CodexIntegrationMode??
  let claudeIntegrationMode: ClaudeIntegrationMode??
  let currentTurnId: String??
  let turnCount: UInt64?
  let branch: String??
  let gitSha: String??
  let currentCwd: String??
  let model: String??
  let effort: String??
  let lastActivityAt: Date?
  let repositoryRoot: String??
  let isWorktree: Bool?
  let unreadCount: UInt64?

  static func from(_ changes: ServerStateChanges) -> SessionStateProjection {
    SessionStateProjection(
      status: changes.status.map { $0 == .active ? .active : .ended },
      workStatus: changes.workStatus.map { $0.toSessionWorkStatus() },
      attentionReason: changes.workStatus.map { $0.toAttentionReason() },
      tokenUsage: changes.tokenUsage,
      tokenUsageSnapshotKind: changes.tokenUsageSnapshotKind,
      currentDiff: changes.currentDiff,
      plan: changes.currentPlan,
      customName: changes.customName,
      summary: changes.summary,
      firstPrompt: changes.firstPrompt,
      lastMessage: changes.lastMessage,
      codexIntegrationMode: changes.codexIntegrationMode.map { $0?.toSessionMode() },
      claudeIntegrationMode: changes.claudeIntegrationMode.map { $0?.toSessionMode() },
      currentTurnId: changes.currentTurnId,
      turnCount: changes.turnCount,
      branch: changes.gitBranch,
      gitSha: changes.gitSha,
      currentCwd: changes.currentCwd,
      model: changes.model,
      effort: changes.effort,
      lastActivityAt: Self.parseLastActivityAt(changes.lastActivityAt),
      repositoryRoot: changes.repositoryRoot,
      isWorktree: changes.isWorktree,
      unreadCount: changes.unreadCount
    )
  }

  private static func parseLastActivityAt(_ rawValue: String?) -> Date? {
    guard let rawValue else { return nil }
    let stripped = rawValue.hasSuffix("Z") ? String(rawValue.dropLast()) : rawValue
    guard let secs = TimeInterval(stripped) else { return nil }
    return Date(timeIntervalSince1970: secs)
  }
}

extension Session {
  mutating func applyProjection(_ projection: SessionStateProjection) {
    if let status = projection.status {
      self.status = status
    }

    if let workStatus = projection.workStatus {
      self.workStatus = workStatus
    }

    if let attentionReason = projection.attentionReason {
      self.attentionReason = attentionReason
    }

    if let tokenUsage = projection.tokenUsage {
      applyTokenUsage(tokenUsage, snapshotKind: projection.tokenUsageSnapshotKind)
    } else if let snapshotKind = projection.tokenUsageSnapshotKind {
      tokenUsageSnapshotKind = snapshotKind
    }

    if let currentDiff = projection.currentDiff {
      self.currentDiff = currentDiff
    }

    if let customName = projection.customName {
      self.customName = customName
    }
    if let summary = projection.summary {
      self.summary = summary
    }
    if let firstPrompt = projection.firstPrompt {
      self.firstPrompt = firstPrompt
    }
    if let lastMessage = projection.lastMessage {
      self.lastMessage = lastMessage
    }
    if let codexIntegrationMode = projection.codexIntegrationMode {
      self.codexIntegrationMode = codexIntegrationMode
    }
    if let claudeIntegrationMode = projection.claudeIntegrationMode {
      self.claudeIntegrationMode = claudeIntegrationMode
    }
    if let branch = projection.branch {
      self.branch = branch
    }
    if let gitSha = projection.gitSha {
      self.gitSha = gitSha
    }
    if let currentCwd = projection.currentCwd {
      self.currentCwd = currentCwd
    }
    if let model = projection.model {
      self.model = model
    }
    if let effort = projection.effort {
      self.effort = effort
    }
    if let lastActivityAt = projection.lastActivityAt {
      self.lastActivityAt = lastActivityAt
    }
    if let repositoryRoot = projection.repositoryRoot {
      self.repositoryRoot = repositoryRoot
    }
    if let isWorktree = projection.isWorktree {
      self.isWorktree = isWorktree
    }
    if let unreadCount = projection.unreadCount {
      self.unreadCount = unreadCount
    }
  }

  mutating func applyTokenUsage(
    _ usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind? = nil
  ) {
    inputTokens = Int(usage.inputTokens)
    outputTokens = Int(usage.outputTokens)
    cachedTokens = Int(usage.cachedTokens)
    contextWindow = Int(usage.contextWindow)
    totalTokens = Int(usage.inputTokens + usage.outputTokens)
    if let snapshotKind {
      tokenUsageSnapshotKind = snapshotKind
    }
  }
}

@MainActor
extension SessionObservable {
  func applyProjection(_ projection: SessionStateProjection) {
    if let status = projection.status {
      self.status = status
    }

    if let workStatus = projection.workStatus {
      self.workStatus = workStatus
      if workStatus == .working {
        promptSuggestions.removeAll()
        rateLimitInfo = nil
      }
    }

    if let attentionReason = projection.attentionReason {
      self.attentionReason = attentionReason
    }

    if let tokenUsage = projection.tokenUsage {
      applyTokenUsage(tokenUsage, snapshotKind: projection.tokenUsageSnapshotKind)
    } else if let snapshotKind = projection.tokenUsageSnapshotKind {
      tokenUsageSnapshotKind = snapshotKind
    }

    if let currentDiff = projection.currentDiff {
      diff = currentDiff
    }
    if let plan = projection.plan {
      self.plan = plan
    }
    if let customName = projection.customName {
      self.customName = customName
    }
    if let summary = projection.summary {
      self.summary = summary
    }
    if let firstPrompt = projection.firstPrompt {
      self.firstPrompt = firstPrompt
    }
    if let lastMessage = projection.lastMessage {
      self.lastMessage = lastMessage
    }
    if let codexIntegrationMode = projection.codexIntegrationMode {
      self.codexIntegrationMode = codexIntegrationMode
    }
    if let claudeIntegrationMode = projection.claudeIntegrationMode {
      self.claudeIntegrationMode = claudeIntegrationMode
    }
    if let currentTurnId = projection.currentTurnId {
      self.currentTurnId = currentTurnId
    }
    if let turnCount = projection.turnCount {
      self.turnCount = turnCount
    }
    if let branch = projection.branch {
      self.branch = branch
    }
    if let gitSha = projection.gitSha {
      self.gitSha = gitSha
    }
    if let currentCwd = projection.currentCwd {
      self.currentCwd = currentCwd
    }
    if let model = projection.model {
      self.model = model
    }
    if let effort = projection.effort {
      self.effort = effort
    }
    if let lastActivityAt = projection.lastActivityAt {
      self.lastActivityAt = lastActivityAt
    }
    if let repositoryRoot = projection.repositoryRoot {
      self.repositoryRoot = repositoryRoot
    }
    if let isWorktree = projection.isWorktree {
      self.isWorktree = isWorktree
    }
    if let unreadCount = projection.unreadCount {
      self.unreadCount = unreadCount
    }
  }

  func applyTokenUsage(
    _ usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind? = nil
  ) {
    tokenUsage = usage
    inputTokens = Int(usage.inputTokens)
    outputTokens = Int(usage.outputTokens)
    cachedTokens = Int(usage.cachedTokens)
    contextWindow = Int(usage.contextWindow)
    totalTokens = Int(usage.inputTokens + usage.outputTokens)
    if let snapshotKind {
      tokenUsageSnapshotKind = snapshotKind
    }
  }
}
