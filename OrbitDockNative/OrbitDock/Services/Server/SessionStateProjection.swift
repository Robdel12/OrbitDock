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

// MARK: - SessionObservable ← ServerSessionState (snapshot)

@MainActor
extension SessionObservable {
  func applyServerSnapshot(_ state: ServerSessionState) {
    let resolvedProvider = serverProvider(state.provider)
    projectPath = state.projectPath
    projectName = state.projectName
    branch = state.gitBranch
    model = state.model
    effort = state.effort
    collaborationMode = state.collaborationMode
    multiAgent = state.multiAgent
    personality = state.personality
    serviceTier = state.serviceTier
    developerInstructions = state.developerInstructions
    codexConfigSource = state.codexConfigSource
    codexConfigMode = state.codexConfigMode
    codexConfigProfile = state.codexConfigProfile
    codexModelProvider = state.codexModelProvider
    codexConfigOverrides = state.codexConfigOverrides
    summary = state.summary
    customName = state.customName
    firstPrompt = state.firstPrompt
    lastMessage = state.lastMessage
    transcriptPath = state.transcriptPath
    status = state.status == .active ? .active : .ended
    workStatus = state.workStatus.toSessionWorkStatus()
    steerable = state.steerable
    attentionReason = state.workStatus.toAttentionReason()
    lastActivityAt = parseServerTimestamp(state.lastActivityAt)
    inputTokens = Int(state.tokenUsage.inputTokens)
    outputTokens = Int(state.tokenUsage.outputTokens)
    cachedTokens = Int(state.tokenUsage.cachedTokens)
    contextWindow = Int(state.tokenUsage.contextWindow)
    totalTokens = Int(state.tokenUsage.inputTokens + state.tokenUsage.outputTokens)
    provider = resolvedProvider
    codexIntegrationMode = serverCodexMode(provider: state.provider, mode: state.codexIntegrationMode)
    claudeIntegrationMode = serverClaudeMode(provider: state.provider, mode: state.claudeIntegrationMode)
    pendingApprovalId = state.pendingApprovalId
    pendingToolName = state.pendingToolName
    pendingToolInput = state.pendingToolInput
    pendingQuestion = state.pendingQuestion
    startedAt = parseServerTimestamp(state.startedAt)
    tokenUsageSnapshotKind = state.tokenUsageSnapshotKind
    gitSha = state.gitSha
    currentCwd = state.currentCwd
    repositoryRoot = state.repositoryRoot
    isWorktree = state.isWorktree ?? false
    worktreeId = state.worktreeId
    unreadCount = state.unreadCount ?? 0
    diff = state.currentDiff
    cumulativeDiff = state.cumulativeDiff
    plan = state.currentPlan
    turnDiffs = state.turnDiffs
    currentTurnId = state.currentTurnId
    turnCount = state.turnCount
    subagents = state.subagents
    missionId = state.missionId
    issueIdentifier = state.issueIdentifier
    allowBypassPermissions = state.allowBypassPermissions ?? false
  }

  /// Apply the session summary returned by the resume HTTP response.
  /// Updates the critical fields that drive the ended→active state transition
  /// so the UI reflects the resumed session immediately rather than waiting
  /// for a WS event.
  func applyResumeSummary(_ summary: ServerSessionSummary) {
    status = summary.status == .active ? .active : .ended
    workStatus = summary.workStatus.toSessionWorkStatus()
    steerable = summary.steerable
    attentionReason = summary.workStatus.toAttentionReason()
    endedAt = nil
    endReason = nil
    if let m = summary.model { model = m }
    if let e = summary.effort { effort = e }
    if let b = summary.gitBranch { branch = b }
  }

  /// Apply incremental state changes from a SessionDelta event.
  func applyServerDelta(_ changes: ServerStateChanges) {
    if let serverStatus = changes.status {
      status = serverStatus == .active ? .active : .ended
    }

    if let serverWorkStatus = changes.workStatus {
      workStatus = serverWorkStatus.toSessionWorkStatus()
      attentionReason = serverWorkStatus.toAttentionReason()
      if workStatus == .working {
        promptSuggestions.removeAll()
        rateLimitInfo = nil
      }
    }

    if let steerable = changes.steerable {
      self.steerable = steerable
    }

    if let tokenUsage = changes.tokenUsage {
      applyTokenUsage(tokenUsage, snapshotKind: changes.tokenUsageSnapshotKind)
    } else if let snapshotKind = changes.tokenUsageSnapshotKind {
      tokenUsageSnapshotKind = snapshotKind
    }

    if let currentDiff = changes.currentDiff {
      diff = currentDiff
    }
    if let cumulativeDiff = changes.cumulativeDiff {
      self.cumulativeDiff = cumulativeDiff
    }
    if let plan = changes.currentPlan {
      self.plan = plan
    }
    if let customName = changes.customName {
      self.customName = customName
    }
    if let summary = changes.summary {
      self.summary = summary
    }
    if let firstPrompt = changes.firstPrompt {
      self.firstPrompt = firstPrompt
    }
    if let lastMessage = changes.lastMessage {
      self.lastMessage = lastMessage
    }
    if let codexIntegrationMode = changes.codexIntegrationMode {
      self.codexIntegrationMode = codexIntegrationMode.map { $0.toSessionMode() }
    }
    if let claudeIntegrationMode = changes.claudeIntegrationMode {
      self.claudeIntegrationMode = claudeIntegrationMode.map { $0.toSessionMode() }
    }
    if let currentTurnId = changes.currentTurnId {
      self.currentTurnId = currentTurnId
    }
    if let turnCount = changes.turnCount {
      self.turnCount = turnCount
    }
    if let branch = changes.gitBranch {
      self.branch = branch
    }
    if let gitSha = changes.gitSha {
      self.gitSha = gitSha
    }
    if let currentCwd = changes.currentCwd {
      self.currentCwd = currentCwd
    }
    if let subagents = changes.subagents {
      self.subagents = subagents
    }
    if let model = changes.model {
      self.model = model
    }
    if let effort = changes.effort {
      self.effort = effort
    }
    if let collaborationMode = changes.collaborationMode {
      self.collaborationMode = collaborationMode
    }
    if let multiAgent = changes.multiAgent {
      self.multiAgent = multiAgent
    }
    if let personality = changes.personality {
      self.personality = personality
    }
    if let serviceTier = changes.serviceTier {
      self.serviceTier = serviceTier
    }
    if let developerInstructions = changes.developerInstructions {
      self.developerInstructions = developerInstructions
    }
    if let codexConfigMode = changes.codexConfigMode {
      self.codexConfigMode = codexConfigMode
    }
    if let codexConfigProfile = changes.codexConfigProfile {
      self.codexConfigProfile = codexConfigProfile
    }
    if let codexModelProvider = changes.codexModelProvider {
      self.codexModelProvider = codexModelProvider
    }
    if let codexConfigSource = changes.codexConfigSource {
      self.codexConfigSource = codexConfigSource
    }
    if let codexConfigOverrides = changes.codexConfigOverrides {
      self.codexConfigOverrides = codexConfigOverrides
    }
    if let lastActivityAt = changes.lastActivityAt {
      self.lastActivityAt = parseServerTimestamp(lastActivityAt)
    }
    if let repositoryRoot = changes.repositoryRoot {
      self.repositoryRoot = repositoryRoot
    }
    if let isWorktree = changes.isWorktree {
      self.isWorktree = isWorktree
    }
    if let unreadCount = changes.unreadCount {
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

  /// Populate observable from a Session struct (preview/demo only).
  func populateFromPreviewSession(_ session: Session) {
    endpointId = session.endpointId
    endpointName = session.endpointName
    endpointConnectionStatus = session.endpointConnectionStatus
    projectPath = session.projectPath
    projectName = session.projectName
    branch = session.branch
    model = session.model
    effort = session.effort
    collaborationMode = session.collaborationMode
    multiAgent = session.multiAgent
    personality = session.personality
    serviceTier = session.serviceTier
    developerInstructions = session.developerInstructions
    codexConfigSource = session.codexConfigSource
    codexConfigMode = session.codexConfigMode
    codexConfigProfile = session.codexConfigProfile
    codexModelProvider = session.codexModelProvider
    codexConfigOverrides = session.codexConfigOverrides
    summary = session.summary
    customName = session.customName
    firstPrompt = session.firstPrompt
    lastMessage = session.lastMessage
    transcriptPath = session.transcriptPath
    status = session.status
    workStatus = session.workStatus
    steerable = session.steerable
    attentionReason = session.attentionReason
    lastActivityAt = session.lastActivityAt
    lastFilesPersistedAt = session.lastFilesPersistedAt
    lastTool = session.lastTool
    lastToolAt = session.lastToolAt
    inputTokens = session.inputTokens
    outputTokens = session.outputTokens
    cachedTokens = session.cachedTokens
    contextWindow = session.contextWindow
    totalTokens = session.totalTokens
    totalCostUSD = session.totalCostUSD
    provider = session.provider
    codexIntegrationMode = session.codexIntegrationMode
    claudeIntegrationMode = session.claudeIntegrationMode
    codexThreadId = session.codexThreadId
    pendingApprovalId = session.pendingApprovalId
    pendingToolName = session.pendingToolName
    pendingToolInput = session.pendingToolInput
    pendingPermissionDetail = session.pendingPermissionDetail
    pendingQuestion = session.pendingQuestion
    promptCount = session.promptCount
    toolCount = session.toolCount
    startedAt = session.startedAt
    endedAt = session.endedAt
    endReason = session.endReason
    tokenUsageSnapshotKind = session.tokenUsageSnapshotKind
    gitSha = session.gitSha
    currentCwd = session.currentCwd
    repositoryRoot = session.repositoryRoot
    isWorktree = session.isWorktree
    worktreeId = session.worktreeId
    unreadCount = session.unreadCount
    diff = session.currentDiff
    cumulativeDiff = session.cumulativeDiff
    missionId = session.missionId
    issueIdentifier = session.issueIdentifier
  }
}

// MARK: - Private Helpers

private func serverProvider(_ provider: ServerProvider) -> Provider {
  provider == .codex ? .codex : .claude
}

private func serverCodexMode(
  provider: ServerProvider,
  mode: ServerCodexIntegrationMode?
) -> CodexIntegrationMode? {
  guard provider == .codex else { return nil }
  return mode?.toSessionMode() ?? .direct
}

private func serverClaudeMode(
  provider: ServerProvider,
  mode: ServerClaudeIntegrationMode?
) -> ClaudeIntegrationMode? {
  guard provider == .claude else { return nil }
  return mode?.toSessionMode()
}

