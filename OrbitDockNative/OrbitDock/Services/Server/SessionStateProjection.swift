import Foundation

struct SessionPendingApprovalProjection {
  let id: String
  let toolName: String?
  let toolInput: String?
  let permissionDetail: String?
  let question: String?
  let attentionReason: Session.AttentionReason
  let workStatus: Session.WorkStatus

  init(request: ServerApprovalRequest) {
    id = request.id
    toolName = request.toolNameForDisplay
    toolInput = request.toolInputForDisplay
    permissionDetail = request.preview?.compact
      ?? String.shellCommandDisplay(from: request.command)
      ?? request.command
    question = request.questionPrompts.first?.question ?? request.question
    attentionReason = request.type == .question ? .awaitingQuestion : .awaitingPermission
    workStatus = .permission
  }
}

struct SessionDetailSnapshotProjection {
  let endpointId: UUID?
  let endpointName: String?
  let projectPath: String
  let projectName: String?
  let branch: String?
  let model: String?
  let effort: String?
  let collaborationMode: String?
  let multiAgent: Bool?
  let personality: String?
  let serviceTier: String?
  let developerInstructions: String?
  let summary: String?
  let customName: String?
  let firstPrompt: String?
  let lastMessage: String?
  let transcriptPath: String?
  let status: Session.SessionStatus
  let workStatus: Session.WorkStatus
  let attentionReason: Session.AttentionReason
  let lastActivityAt: Date?
  let lastFilesPersistedAt: Date?
  let lastTool: String?
  let lastToolAt: Date?
  let inputTokens: Int?
  let outputTokens: Int?
  let cachedTokens: Int?
  let contextWindow: Int?
  let totalTokens: Int
  let totalCostUSD: Double
  let provider: Provider
  let codexIntegrationMode: CodexIntegrationMode?
  let claudeIntegrationMode: ClaudeIntegrationMode?
  let codexThreadId: String?
  let pendingApprovalId: String?
  let pendingToolName: String?
  let pendingToolInput: String?
  let pendingPermissionDetail: String?
  let pendingQuestion: String?
  let promptCount: Int
  let toolCount: Int
  let startedAt: Date?
  let endedAt: Date?
  let endReason: String?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind
  let gitSha: String?
  let currentCwd: String?
  let repositoryRoot: String?
  let isWorktree: Bool
  let worktreeId: String?
  let unreadCount: UInt64
  let missionId: String?
  let issueIdentifier: String?
  let allowBypassPermissions: Bool

  static func from(_ session: Session) -> SessionDetailSnapshotProjection {
    SessionDetailSnapshotProjection(
      endpointId: session.endpointId,
      endpointName: session.endpointName,
      projectPath: session.projectPath,
      projectName: session.projectName,
      branch: session.branch,
      model: session.model,
      effort: session.effort,
      collaborationMode: session.collaborationMode,
      multiAgent: session.multiAgent,
      personality: session.personality,
      serviceTier: session.serviceTier,
      developerInstructions: session.developerInstructions,
      summary: session.summary,
      customName: session.customName,
      firstPrompt: session.firstPrompt,
      lastMessage: session.lastMessage,
      transcriptPath: session.transcriptPath,
      status: session.status,
      workStatus: session.workStatus,
      attentionReason: session.attentionReason,
      lastActivityAt: session.lastActivityAt,
      lastFilesPersistedAt: session.lastFilesPersistedAt,
      lastTool: session.lastTool,
      lastToolAt: session.lastToolAt,
      inputTokens: session.inputTokens,
      outputTokens: session.outputTokens,
      cachedTokens: session.cachedTokens,
      contextWindow: session.contextWindow,
      totalTokens: session.totalTokens,
      totalCostUSD: session.totalCostUSD,
      provider: session.provider,
      codexIntegrationMode: session.codexIntegrationMode,
      claudeIntegrationMode: session.claudeIntegrationMode,
      codexThreadId: session.codexThreadId,
      pendingApprovalId: session.pendingApprovalId,
      pendingToolName: session.pendingToolName,
      pendingToolInput: session.pendingToolInput,
      pendingPermissionDetail: session.pendingPermissionDetail,
      pendingQuestion: session.pendingQuestion,
      promptCount: session.promptCount,
      toolCount: session.toolCount,
      startedAt: session.startedAt,
      endedAt: session.endedAt,
      endReason: session.endReason,
      tokenUsageSnapshotKind: session.tokenUsageSnapshotKind,
      gitSha: session.gitSha,
      currentCwd: session.currentCwd,
      repositoryRoot: session.repositoryRoot,
      isWorktree: session.isWorktree,
      worktreeId: session.worktreeId,
      unreadCount: session.unreadCount,
      missionId: session.missionId,
      issueIdentifier: session.issueIdentifier,
      allowBypassPermissions: false
    )
  }
}

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
  let subagents: [ServerSubagentInfo]?
  let model: String??
  let effort: String??
  let collaborationMode: String??
  let multiAgent: Bool??
  let personality: String??
  let serviceTier: String??
  let developerInstructions: String??
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
      subagents: changes.subagents,
      model: changes.model,
      effort: changes.effort,
      collaborationMode: changes.collaborationMode,
      multiAgent: changes.multiAgent,
      personality: changes.personality,
      serviceTier: changes.serviceTier,
      developerInstructions: changes.developerInstructions,
      lastActivityAt: parseLastActivityAt(changes.lastActivityAt),
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

struct SessionTurnDiffSnapshotProjection {
  let turnDiff: ServerTurnDiff?
  let usage: ServerTokenUsage?
  let snapshotKind: ServerTokenUsageSnapshotKind

  static func fromTurnDiffSnapshot(
    turnId: String,
    diff: String?,
    inputTokens: UInt64?,
    outputTokens: UInt64?,
    cachedTokens: UInt64?,
    contextWindow: UInt64?,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) -> SessionTurnDiffSnapshotProjection {
    let turnDiff = diff.map { diff in
      ServerTurnDiff(
        turnId: turnId,
        diff: diff,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cachedTokens: cachedTokens,
        contextWindow: contextWindow,
        snapshotKind: snapshotKind
      )
    }

    return SessionTurnDiffSnapshotProjection(
      turnDiff: turnDiff,
      usage: turnDiff?.tokenUsage,
      snapshotKind: snapshotKind
    )
  }
}

extension Session {
  mutating func applyPendingApprovalProjection(_ projection: SessionPendingApprovalProjection) {
    pendingApprovalId = projection.id
    pendingToolName = projection.toolName
    pendingToolInput = projection.toolInput
    pendingPermissionDetail = projection.permissionDetail
    pendingQuestion = projection.question
    attentionReason = projection.attentionReason
    workStatus = projection.workStatus
  }

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
    if let collaborationMode = projection.collaborationMode {
      self.collaborationMode = collaborationMode
    }
    if let multiAgent = projection.multiAgent {
      self.multiAgent = multiAgent
    }
    if let personality = projection.personality {
      self.personality = personality
    }
    if let serviceTier = projection.serviceTier {
      self.serviceTier = serviceTier
    }
    if let developerInstructions = projection.developerInstructions {
      self.developerInstructions = developerInstructions
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

    refreshDisplayProjection()
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

  mutating func applyTurnDiffSnapshot(_ projection: SessionTurnDiffSnapshotProjection) {
    if let usage = projection.usage {
      applyTokenUsage(usage, snapshotKind: projection.snapshotKind)
    } else {
      tokenUsageSnapshotKind = projection.snapshotKind
    }
  }
}

@MainActor
extension SessionObservable {
  func applySnapshotProjection(_ projection: SessionDetailSnapshotProjection) {
    endpointId = projection.endpointId
    endpointName = projection.endpointName
    projectPath = projection.projectPath
    projectName = projection.projectName
    branch = projection.branch
    model = projection.model
    effort = projection.effort
    collaborationMode = projection.collaborationMode
    multiAgent = projection.multiAgent
    personality = projection.personality
    serviceTier = projection.serviceTier
    developerInstructions = projection.developerInstructions
    summary = projection.summary
    customName = projection.customName
    firstPrompt = projection.firstPrompt
    lastMessage = projection.lastMessage
    transcriptPath = projection.transcriptPath
    status = projection.status
    workStatus = projection.workStatus
    attentionReason = projection.attentionReason
    lastActivityAt = projection.lastActivityAt
    lastFilesPersistedAt = projection.lastFilesPersistedAt
    lastTool = projection.lastTool
    lastToolAt = projection.lastToolAt
    inputTokens = projection.inputTokens
    outputTokens = projection.outputTokens
    cachedTokens = projection.cachedTokens
    contextWindow = projection.contextWindow
    totalTokens = projection.totalTokens
    totalCostUSD = projection.totalCostUSD
    provider = projection.provider
    codexIntegrationMode = projection.codexIntegrationMode
    claudeIntegrationMode = projection.claudeIntegrationMode
    codexThreadId = projection.codexThreadId
    pendingApprovalId = projection.pendingApprovalId
    pendingToolName = projection.pendingToolName
    pendingToolInput = projection.pendingToolInput
    pendingPermissionDetail = projection.pendingPermissionDetail
    pendingQuestion = projection.pendingQuestion
    promptCount = projection.promptCount
    toolCount = projection.toolCount
    startedAt = projection.startedAt
    endedAt = projection.endedAt
    endReason = projection.endReason
    tokenUsageSnapshotKind = projection.tokenUsageSnapshotKind
    gitSha = projection.gitSha
    currentCwd = projection.currentCwd
    repositoryRoot = projection.repositoryRoot
    isWorktree = projection.isWorktree
    worktreeId = projection.worktreeId
    unreadCount = projection.unreadCount
    missionId = projection.missionId
    issueIdentifier = projection.issueIdentifier
    allowBypassPermissions = projection.allowBypassPermissions
  }

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
    if let subagents = projection.subagents {
      self.subagents = subagents
    }
    if let model = projection.model {
      self.model = model
    }
    if let effort = projection.effort {
      self.effort = effort
    }
    if let collaborationMode = projection.collaborationMode {
      self.collaborationMode = collaborationMode
    }
    if let multiAgent = projection.multiAgent {
      self.multiAgent = multiAgent
    }
    if let personality = projection.personality {
      self.personality = personality
    }
    if let serviceTier = projection.serviceTier {
      self.serviceTier = serviceTier
    }
    if let developerInstructions = projection.developerInstructions {
      self.developerInstructions = developerInstructions
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

  func applyTurnDiffSnapshot(_ projection: SessionTurnDiffSnapshotProjection) {
    if let turnDiff = projection.turnDiff {
      if let idx = turnDiffs.firstIndex(where: { $0.turnId == turnDiff.turnId }) {
        turnDiffs[idx] = turnDiff
      } else {
        turnDiffs.append(turnDiff)
      }
    }

    if let usage = projection.usage {
      applyTokenUsage(usage, snapshotKind: projection.snapshotKind)
    } else {
      tokenUsageSnapshotKind = projection.snapshotKind
    }
  }
}
