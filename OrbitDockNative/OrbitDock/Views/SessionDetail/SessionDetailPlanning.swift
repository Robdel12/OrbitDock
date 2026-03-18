import Foundation

struct SessionDetailConversationChromeState: Equatable {
  var isPinned: Bool
  var unreadCount: Int
  var scrollToBottomTrigger: Int
  var pendingApprovalPanelOpenSignal: Int
}

enum SessionDetailConversationChromePlanner {
  static func openPendingApprovalPanel(
    current: SessionDetailConversationChromeState
  ) -> SessionDetailConversationChromeState {
    var next = current
    next.pendingApprovalPanelOpenSignal += 1
    next.isPinned = true
    next.unreadCount = 0
    next.scrollToBottomTrigger += 1
    return next
  }

  static func jumpToLatest(
    current: SessionDetailConversationChromeState
  ) -> SessionDetailConversationChromeState {
    var next = current
    next.isPinned = true
    next.unreadCount = 0
    next.scrollToBottomTrigger += 1
    return next
  }

  static func togglePinned(
    current: SessionDetailConversationChromeState
  ) -> SessionDetailConversationChromeState {
    guard current.isPinned else {
      return jumpToLatest(current: current)
    }

    var next = current
    next.isPinned = false
    return next
  }
}

struct SessionDetailPlanPillState: Equatable {
  let completedCount: Int
  let totalCount: Int

  var isComplete: Bool {
    totalCount > 0 && completedCount == totalCount
  }

  var badgeText: String {
    "\(completedCount)/\(totalCount)"
  }
}

struct SessionDetailChangesPillState: Equatable {
  let badgeText: String
  let openCommentCount: Int
}

struct SessionDetailContextPillState: Equatable {
  let fillPercent: Double
}

struct SessionDetailStatusStripState: Equatable {
  let plan: SessionDetailPlanPillState?
  let changes: SessionDetailChangesPillState?
  let context: SessionDetailContextPillState?

  var showsPlan: Bool {
    plan != nil
  }

  var showsChanges: Bool {
    changes != nil
  }

  var showsContext: Bool {
    context != nil
  }
}

enum SessionDetailStatusStripPlanner {
  static func planState(steps: [Session.PlanStep]?) -> SessionDetailPlanPillState? {
    guard let steps, !steps.isEmpty else { return nil }
    return SessionDetailPlanPillState(
      completedCount: steps.filter(\.isCompleted).count,
      totalCount: steps.count
    )
  }

  static func changesState(
    diff: String?,
    reviewComments: [ServerReviewComment]
  ) -> SessionDetailChangesPillState? {
    let openCommentCount = reviewComments.filter { $0.status == .open }.count
    let hasComments = !reviewComments.isEmpty
    let diffState = diff.flatMap { SessionDetailDiffPlanner.changeSummary($0) }

    guard diffState != nil || hasComments else { return nil }

    let badgeText =
      if let diffState {
        diffState.badgeText
      } else {
        "\(openCommentCount) comment\(openCommentCount == 1 ? "" : "s")"
      }

    return SessionDetailChangesPillState(
      badgeText: badgeText,
      openCommentCount: openCommentCount
    )
  }

  static func contextState(
    tokenUsage: ServerTokenUsage?,
    snapshotKind: ServerTokenUsageSnapshotKind,
    provider: Provider
  ) -> SessionDetailContextPillState? {
    guard let tokenUsage, tokenUsage.contextWindow > 0 else { return nil }
    let input = SessionTokenUsageSemantics.effectiveContextInputTokens(
      inputTokens: Int(tokenUsage.inputTokens),
      cachedTokens: Int(tokenUsage.cachedTokens),
      snapshotKind: snapshotKind,
      provider: provider
    )
    let fillPercent = min(Double(input) / Double(tokenUsage.contextWindow) * 100, 100)
    return SessionDetailContextPillState(fillPercent: fillPercent)
  }

  static func state(
    steps: [Session.PlanStep]?,
    diff: String?,
    reviewComments: [ServerReviewComment],
    tokenUsage: ServerTokenUsage?,
    snapshotKind: ServerTokenUsageSnapshotKind,
    provider: Provider
  ) -> SessionDetailStatusStripState {
    SessionDetailStatusStripState(
      plan: planState(steps: steps),
      changes: changesState(diff: diff, reviewComments: reviewComments),
      context: contextState(tokenUsage: tokenUsage, snapshotKind: snapshotKind, provider: provider)
    )
  }
}

struct SessionDetailOnAppearPlan: Equatable {
  let shouldSubscribe: Bool
  let autoMarkReadEnabled: Bool
  let shouldLoadApprovalHistory: Bool
}

struct SessionDetailOnDisappearPlan: Equatable {
  let shouldSetAutoMarkRead: Bool
  let autoMarkReadEnabled: Bool
  let shouldUnsubscribe: Bool
}

enum SessionDetailLifecyclePlanner {
  static func onAppearPlan(
    shouldSubscribeToServerSession: Bool,
    isDirect: Bool,
    isPinned: Bool
  ) -> SessionDetailOnAppearPlan {
    SessionDetailOnAppearPlan(
      shouldSubscribe: shouldSubscribeToServerSession,
      autoMarkReadEnabled: isPinned,
      shouldLoadApprovalHistory: shouldSubscribeToServerSession && isDirect
    )
  }

  static func onDisappearPlan(
    shouldSubscribeToServerSession: Bool
  ) -> SessionDetailOnDisappearPlan {
    SessionDetailOnDisappearPlan(
      shouldSetAutoMarkRead: shouldSubscribeToServerSession,
      autoMarkReadEnabled: false,
      shouldUnsubscribe: shouldSubscribeToServerSession
    )
  }

  static func autoMarkReadEnabled(
    shouldSubscribeToServerSession: Bool,
    isPinned: Bool
  ) -> Bool? {
    guard shouldSubscribeToServerSession else { return nil }
    return isPinned
  }

  static func shouldRevealDiffBanner(
    isDirect: Bool,
    oldDiff: String?,
    newDiff: String?,
    layoutConfig: LayoutConfiguration
  ) -> Bool {
    isDirect && oldDiff == nil && newDiff != nil && layoutConfig == .conversationOnly
  }
}

enum SessionDetailLayoutIntent {
  case toggleSplitShortcut
  case showReviewOnlyShortcut
  case dismissReview
  case revealReviewSplit
}

enum SessionDetailFooterMode: Equatable {
  case direct
  case passive
}

struct SessionDetailReviewNavigationPlan {
  let reviewFileId: String
  let navigateToComment: ServerReviewComment?
  let layoutConfig: LayoutConfiguration
}

struct SessionDetailDiffSummaryState: Equatable {
  let fileCount: Int
  let totalAdditions: Int
  let totalDeletions: Int

  var badgeText: String {
    "+\(totalAdditions) −\(totalDeletions)"
  }
}

struct SessionDetailActionBarState: Equatable {
  let branchLabel: String?
  let projectPathLabel: String
  let formattedCost: String?
  let lastActivityAt: Date?
  let isPinned: Bool
  let unreadCount: Int

  var showsUnreadIndicator: Bool {
    !isPinned && unreadCount > 0
  }

  var unreadBadgeText: String {
    "\(unreadCount)"
  }

  var followLabel: String {
    isPinned ? "Following" : "Paused"
  }

  var compactFollowIcon: String {
    isPinned ? "arrow.down.to.line" : "pause"
  }
}

enum SessionDetailMetadataPlanner {
  nonisolated static func compactBranchLabel(_ branch: String) -> String {
    let maxLength = 14
    guard branch.count > maxLength else { return branch }
    return String(branch.prefix(maxLength - 1)) + "…"
  }

  nonisolated static func compactProjectPath(_ path: String) -> String {
    let components = path.split(separator: "/")
    if components.count >= 2 {
      return components.suffix(2).joined(separator: "/")
    }
    return path
  }
}

enum SessionDetailActionBarPlanner {
  nonisolated static func formattedCost(_ cost: Double) -> String {
    String(format: "$%.2f", cost)
  }

  nonisolated static func state(
    branch: String?,
    projectPath: String,
    usageStats: TranscriptUsageStats,
    isPinned: Bool,
    unreadCount: Int,
    lastActivityAt: Date?
  ) -> SessionDetailActionBarState {
    SessionDetailActionBarState(
      branchLabel: branch.map(SessionDetailMetadataPlanner.compactBranchLabel),
      projectPathLabel: SessionDetailMetadataPlanner.compactProjectPath(projectPath),
      formattedCost: usageStats.estimatedCostUSD > 0 ? formattedCost(usageStats.estimatedCostUSD) : nil,
      lastActivityAt: lastActivityAt,
      isPinned: isPinned,
      unreadCount: unreadCount
    )
  }
}

enum SessionDetailLayoutPlanner {
  static func nextLayout(
    currentLayout: LayoutConfiguration,
    intent: SessionDetailLayoutIntent
  ) -> LayoutConfiguration {
    switch intent {
      case .toggleSplitShortcut:
        currentLayout == .conversationOnly ? .split : .conversationOnly
      case .showReviewOnlyShortcut:
        .reviewOnly
      case .dismissReview:
        .conversationOnly
      case .revealReviewSplit:
        currentLayout == .conversationOnly ? .split : currentLayout
    }
  }

  static func reviewFileNavigationPlan(
    sessionId: String,
    currentLayout: LayoutConfiguration,
    filePath: String,
    lineNumber: Int
  ) -> SessionDetailReviewNavigationPlan {
    SessionDetailReviewNavigationPlan(
      reviewFileId: filePath,
      navigateToComment: ServerReviewComment(
        id: "nav-\(filePath)-\(lineNumber)",
        sessionId: sessionId,
        turnId: nil,
        filePath: filePath,
        lineStart: UInt32(lineNumber),
        lineEnd: nil,
        body: "",
        tag: nil,
        status: .resolved,
        createdAt: "",
        updatedAt: nil
      ),
      layoutConfig: nextLayout(currentLayout: currentLayout, intent: .revealReviewSplit)
    )
  }

  static func openFileInReviewPlan(
    projectPath: String,
    currentLayout: LayoutConfiguration,
    filePath: String
  ) -> SessionDetailReviewNavigationPlan {
    let reviewFileId =
      if filePath.hasPrefix(projectPath) {
        String(filePath.dropFirst(projectPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      } else {
        filePath
      }

    return SessionDetailReviewNavigationPlan(
      reviewFileId: reviewFileId,
      navigateToComment: nil,
      layoutConfig: nextLayout(currentLayout: currentLayout, intent: .revealReviewSplit)
    )
  }
}

enum SessionDetailDiffPlanner {
  static func changeSummary(_ diff: String?) -> SessionDetailDiffSummaryState? {
    guard let diff, !diff.isEmpty else { return nil }
    let model = DiffModel.parse(unifiedDiff: diff)
    return SessionDetailDiffSummaryState(
      fileCount: model.files.count,
      totalAdditions: model.files.reduce(0) { $0 + $1.stats.additions },
      totalDeletions: model.files.reduce(0) { $0 + $1.stats.deletions }
    )
  }

  static func fileCount(
    turnDiffs: [ServerTurnDiff],
    currentDiff: String?
  ) -> Int {
    var parts = turnDiffs.map(\.diff)

    if let currentDiff, !currentDiff.isEmpty, turnDiffs.last?.diff != currentDiff {
      parts.append(currentDiff)
    }

    let combined = parts.joined(separator: "\n")
    guard !combined.isEmpty else { return 0 }
    return DiffModel.parse(unifiedDiff: combined).files.count
  }
}

enum SessionDetailFooterPlanner {
  static func mode(
    isDirect: Bool,
    canTakeOver: Bool,
    needsApprovalOverlay: Bool
  ) -> SessionDetailFooterMode {
    // canTakeOver means the user doesn't own this session — show passive view
    // with takeover option. isDirect alone isn't enough because docked
    // sessions can be isDirect but not owned.
    if canTakeOver { return .passive }
    if isDirect { return .direct }
    return .passive
  }
}

struct SessionDetailWorktreeCleanupBannerState: Equatable {
  let branchName: String
  let canCleanUp: Bool
}

struct SessionDetailWorktreeCleanupRequest: Equatable {
  let worktreeId: String
  let force: Bool
  let deleteBranch: Bool
}

enum SessionDetailUsagePlanner {
  static func makeStats(
    model: String?,
    inputTokens: Int?,
    outputTokens: Int?,
    cachedTokens: Int?,
    contextUsed: Int,
    totalTokens: Int,
    costCalculator: TokenCostCalculator
  ) -> TranscriptUsageStats {
    var stats = TranscriptUsageStats()
    stats.model = model

    let input = inputTokens ?? 0
    let output = outputTokens ?? 0
    let cached = cachedTokens ?? 0
    let hasServerUsage = input > 0 || output > 0 || cached > 0 || contextUsed > 0

    if hasServerUsage {
      stats.inputTokens = input
      stats.outputTokens = output
      stats.cacheReadTokens = cached
      stats.contextUsed = contextUsed
    } else {
      stats.outputTokens = max(totalTokens, 0)
    }

    stats.estimatedCostUSD = costCalculator.calculateCost(
      model: model,
      inputTokens: stats.inputTokens,
      outputTokens: stats.outputTokens,
      cacheReadTokens: stats.cacheReadTokens,
      cacheCreationTokens: stats.cacheCreationTokens
    )

    return stats
  }
}

enum SessionDetailWorktreeCleanupPlanner {
  static func shouldShowBanner(
    status: Session.SessionStatus,
    isWorktree: Bool,
    dismissed: Bool
  ) -> Bool {
    status == .ended && isWorktree && !dismissed
  }

  static func resolveWorktree(
    worktreesByRepo: [String: [ServerWorktreeSummary]],
    worktreeId: String?,
    projectPath: String
  ) -> ServerWorktreeSummary? {
    let worktrees = worktreesByRepo.values.flatMap { $0 }
    if let worktreeId {
      return worktrees.first { $0.id == worktreeId }
    }
    return worktrees.first { $0.worktreePath == projectPath }
  }

  static func bannerState(
    status: Session.SessionStatus,
    isWorktree: Bool,
    dismissed: Bool,
    worktree: ServerWorktreeSummary?,
    branch: String?,
    isCleaningUp: Bool
  ) -> SessionDetailWorktreeCleanupBannerState? {
    guard shouldShowBanner(status: status, isWorktree: isWorktree, dismissed: dismissed) else { return nil }

    return SessionDetailWorktreeCleanupBannerState(
      branchName: worktree?.branch ?? branch ?? "unknown",
      canCleanUp: !isCleaningUp && worktree != nil
    )
  }

  static func cleanupRequest(
    worktree: ServerWorktreeSummary?,
    deleteBranch: Bool
  ) -> SessionDetailWorktreeCleanupRequest? {
    guard let worktree else { return nil }
    return SessionDetailWorktreeCleanupRequest(
      worktreeId: worktree.id,
      force: true,
      deleteBranch: deleteBranch
    )
  }
}
