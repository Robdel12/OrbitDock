import Foundation
@testable import OrbitDock
import Testing

struct SessionDetailPlanningTests {
  private let costCalculator = TokenCostCalculator(
    prices: [
      "claude-opus-4": ModelPrice(
        inputCostPerToken: 1.0,
        outputCostPerToken: 2.0,
        cacheReadInputTokenCost: 0.5,
        cacheCreationInputTokenCost: 4.0
      ),
    ]
  )

  @Test func openingPendingApprovalPanelPinsConversationAndClearsUnreadState() {
    let next = SessionDetailConversationChromePlanner.openPendingApprovalPanel(
      current: SessionDetailConversationChromeState(
        isPinned: false,
        unreadCount: 6,
        scrollToBottomTrigger: 2,
        pendingApprovalPanelOpenSignal: 4
      )
    )

    #expect(next.isPinned)
    #expect(next.unreadCount == 0)
    #expect(next.scrollToBottomTrigger == 3)
    #expect(next.pendingApprovalPanelOpenSignal == 5)
  }

  @Test func togglingPinnedFromPausedJumpsToLatest() {
    let next = SessionDetailConversationChromePlanner.togglePinned(
      current: SessionDetailConversationChromeState(
        isPinned: false,
        unreadCount: 3,
        scrollToBottomTrigger: 9,
        pendingApprovalPanelOpenSignal: 1
      )
    )

    #expect(next.isPinned)
    #expect(next.unreadCount == 0)
    #expect(next.scrollToBottomTrigger == 10)
    #expect(next.pendingApprovalPanelOpenSignal == 1)
  }

  @Test func togglingPinnedFromFollowingOnlyPauses() {
    let next = SessionDetailConversationChromePlanner.togglePinned(
      current: SessionDetailConversationChromeState(
        isPinned: true,
        unreadCount: 2,
        scrollToBottomTrigger: 7,
        pendingApprovalPanelOpenSignal: 3
      )
    )

    #expect(!next.isPinned)
    #expect(next.unreadCount == 2)
    #expect(next.scrollToBottomTrigger == 7)
    #expect(next.pendingApprovalPanelOpenSignal == 3)
  }

  @Test func onAppearPlanSubscribesAndLoadsApprovalsForDirectSessions() {
    let plan = SessionDetailLifecyclePlanner.onAppearPlan(
      shouldSubscribeToServerSession: true,
      isDirect: true,
      isPinned: false
    )

    #expect(plan.shouldSubscribe)
    #expect(!plan.autoMarkReadEnabled)
    #expect(plan.shouldLoadApprovalHistory)
  }

  @Test func diffBannerRevealRequiresFirstDirectDiffInConversationLayout() {
    #expect(
      SessionDetailLifecyclePlanner.shouldRevealDiffBanner(
        isDirect: true,
        oldDiff: nil,
        newDiff: "diff --git a/file b/file",
        layoutConfig: .conversationOnly
      )
    )
    #expect(
      !SessionDetailLifecyclePlanner.shouldRevealDiffBanner(
        isDirect: false,
        oldDiff: nil,
        newDiff: "diff --git a/file b/file",
        layoutConfig: .conversationOnly
      )
    )
    #expect(
      !SessionDetailLifecyclePlanner.shouldRevealDiffBanner(
        isDirect: true,
        oldDiff: "already had one",
        newDiff: "diff --git a/file b/file",
        layoutConfig: .conversationOnly
      )
    )
  }

  @Test func layoutPlannerBuildsReviewNavigationFromConversationRows() {
    let plan = SessionDetailLayoutPlanner.reviewFileNavigationPlan(
      sessionId: "session-1",
      currentLayout: .conversationOnly,
      filePath: "Sources/App.swift",
      lineNumber: 42
    )

    #expect(plan.reviewFileId == "Sources/App.swift")
    #expect(plan.layoutConfig == .split)
    #expect(plan.navigateToComment?.id == "nav-Sources/App.swift-42")
    #expect(plan.navigateToComment?.lineStart == 42)
  }

  @Test func layoutPlannerNormalizesProjectRelativeOpenInReviewPath() {
    let plan = SessionDetailLayoutPlanner.openFileInReviewPlan(
      projectPath: "/tmp/repo",
      currentLayout: .reviewOnly,
      filePath: "/tmp/repo/Sources/App.swift"
    )

    #expect(plan.reviewFileId == "Sources/App.swift")
    #expect(plan.layoutConfig == .reviewOnly)
    #expect(plan.navigateToComment == nil)
  }

  @Test func footerPlannerShowsPassiveForNonOwnedSessions() {
    // canTakeOver → passive, even if isDirect
    #expect(
      isPassiveFooterMode(
        SessionDetailFooterPlanner.mode(
          isDirect: true,
          canTakeOver: true,
          needsApprovalOverlay: false
        )
      )
    )
    // canTakeOver with approval → still passive (approval visible in timeline)
    #expect(
      isPassiveFooterMode(
        SessionDetailFooterPlanner.mode(
          isDirect: false,
          canTakeOver: true,
          needsApprovalOverlay: true
        )
      )
    )
    // isDirect without canTakeOver → direct (user owns it)
    #expect(
      isDirectFooterMode(
        SessionDetailFooterPlanner.mode(
          isDirect: true,
          canTakeOver: false,
          needsApprovalOverlay: false
        )
      )
    )
    // Not direct, can't take over → passive
    #expect(
      isPassiveFooterMode(
        SessionDetailFooterPlanner.mode(
          isDirect: false,
          canTakeOver: false,
          needsApprovalOverlay: false
        )
      )
    )
  }

  @Test func metadataPlannerTruncatesLongBranchNamesAndKeepsShortPathsReadable() {
    #expect(
      SessionDetailMetadataPlanner.compactBranchLabel("feature/super-long-branch-name")
        == "feature/super…"
    )
    #expect(
      SessionDetailMetadataPlanner.compactProjectPath("/tmp/repo/feature-a")
        == "repo/feature-a"
    )
    #expect(SessionDetailMetadataPlanner.compactProjectPath("repo") == "repo")
  }

  @Test func actionBarPlannerProjectsReadableDisplayState() {
    var stats = TranscriptUsageStats()
    stats.outputTokens = 42
    stats.estimatedCostUSD = 1.25

    let lastActivity = Date(timeIntervalSince1970: 123)
    let state = SessionDetailActionBarPlanner.state(
      branch: "feature/super-long-branch-name",
      projectPath: "/tmp/repo/feature-a",
      usageStats: stats,
      isPinned: false,
      unreadCount: 3,
      lastActivityAt: lastActivity
    )

    #expect(state.branchLabel == "feature/super…")
    #expect(state.projectPathLabel == "repo/feature-a")
    #expect(state.formattedCost == stats.formattedCost)
    #expect(state.lastActivityAt == lastActivity)
    #expect(state.showsUnreadIndicator)
    #expect(state.unreadBadgeText == "3")
    #expect(state.followLabel == "Paused")
    #expect(state.compactFollowIcon == "pause")
  }

  @Test func actionBarPlannerHidesUnreadIndicatorWhenFollowingAndOmitsZeroCost() {
    let state = SessionDetailActionBarPlanner.state(
      branch: nil,
      projectPath: "repo",
      usageStats: TranscriptUsageStats(),
      isPinned: true,
      unreadCount: 8,
      lastActivityAt: nil
    )

    #expect(state.branchLabel == nil)
    #expect(state.projectPathLabel == "repo")
    #expect(state.formattedCost == nil)
    #expect(!state.showsUnreadIndicator)
    #expect(state.followLabel == "Following")
    #expect(state.compactFollowIcon == "arrow.down.to.line")
  }

  @Test func statusStripPlannerBuildsPlanChangesAndContextSummaries() {
    let status = SessionDetailStatusStripPlanner.state(
      steps: [
        Session.PlanStep(step: "Inspect", status: "completed"),
        Session.PlanStep(step: "Fix", status: "inProgress"),
      ],
      diff: """
      diff --git a/Sources/App.swift b/Sources/App.swift
      index 1111111..2222222 100644
      --- a/Sources/App.swift
      +++ b/Sources/App.swift
      @@ -1 +1,2 @@
      -old
      +new
      +extra
      """,
      reviewComments: [
        makeReviewComment(id: "open", status: .open),
        makeReviewComment(id: "resolved", status: .resolved),
      ],
      tokenUsage: ServerTokenUsage(
        inputTokens: 80,
        outputTokens: 20,
        cachedTokens: 10,
        contextWindow: 200
      ),
      snapshotKind: .lifetimeTotals,
      provider: .claude
    )

    #expect(status.plan?.completedCount == 1)
    #expect(status.plan?.totalCount == 2)
    #expect(status.changes?.badgeText == "+2 −1")
    #expect(status.changes?.openCommentCount == 1)
    #expect(status.context?.fillPercent == 40)
  }

  @Test func statusStripPlannerOmitsEmptySections() {
    let status = SessionDetailStatusStripPlanner.state(
      steps: [],
      diff: nil,
      reviewComments: [],
      tokenUsage: nil,
      snapshotKind: .lifetimeTotals,
      provider: .claude
    )

    #expect(!status.showsPlan)
    #expect(!status.showsChanges)
    #expect(!status.showsContext)
  }

  @Test func usagePlannerPrefersServerUsageAndFallsBackToTotalTokens() {
    let serverStats = SessionDetailUsagePlanner.makeStats(
      model: "claude-opus-4",
      inputTokens: 120,
      outputTokens: 45,
      cachedTokens: 10,
      contextUsed: 300,
      totalTokens: 999,
      costCalculator: costCalculator
    )
    #expect(serverStats.model == "claude-opus-4")
    #expect(serverStats.inputTokens == 120)
    #expect(serverStats.outputTokens == 45)
    #expect(serverStats.cacheReadTokens == 10)
    #expect(serverStats.contextUsed == 300)
    #expect(serverStats.estimatedCostUSD == 215)

    let fallbackStats = SessionDetailUsagePlanner.makeStats(
      model: "claude-opus-4",
      inputTokens: nil,
      outputTokens: nil,
      cachedTokens: nil,
      contextUsed: 0,
      totalTokens: 88,
      costCalculator: costCalculator
    )
    #expect(fallbackStats.inputTokens == 0)
    #expect(fallbackStats.outputTokens == 88)
    #expect(fallbackStats.cacheReadTokens == 0)
    #expect(fallbackStats.contextUsed == 0)
    #expect(fallbackStats.estimatedCostUSD == 176)
  }

  @Test func diffPlannerCountsCombinedTurnSnapshotsWithoutDuplicatingCurrentSnapshot() {
    let count = SessionDetailDiffPlanner.fileCount(
      turnDiffs: [
        makeTurnDiff(
          diff: """
          diff --git a/Sources/App.swift b/Sources/App.swift
          --- a/Sources/App.swift
          +++ b/Sources/App.swift
          @@ -1 +1 @@
          -old
          +new
          """
        ),
      ],
      currentDiff: """
      diff --git a/Sources/Feature.swift b/Sources/Feature.swift
      --- a/Sources/Feature.swift
      +++ b/Sources/Feature.swift
      @@ -1 +1 @@
      -old
      +new
      """
    )
    #expect(count == 2)

    let dedupedCount = SessionDetailDiffPlanner.fileCount(
      turnDiffs: [
        makeTurnDiff(
          diff: """
          diff --git a/Sources/App.swift b/Sources/App.swift
          --- a/Sources/App.swift
          +++ b/Sources/App.swift
          @@ -1 +1 @@
          -old
          +new
          """
        ),
      ],
      currentDiff: """
      diff --git a/Sources/App.swift b/Sources/App.swift
      --- a/Sources/App.swift
      +++ b/Sources/App.swift
      @@ -1 +1 @@
      -old
      +new
      """
    )
    #expect(dedupedCount == 1)
  }

  @Test func worktreeCleanupPlannerResolvesByIdBeforePathAndBuildsRequest() {
    let matchingById = makeWorktree(id: "wt-1", path: "/tmp/repo/worktree-a", branch: "feature/a")
    let matchingByPath = makeWorktree(id: "wt-2", path: "/tmp/repo/worktree-b", branch: "feature/b")

    let resolved = SessionDetailWorktreeCleanupPlanner.resolveWorktree(
      worktreesByRepo: ["/tmp/repo": [matchingById, matchingByPath]],
      worktreeId: "wt-1",
      projectPath: "/tmp/repo/worktree-b"
    )
    let request = SessionDetailWorktreeCleanupPlanner.cleanupRequest(
      worktree: resolved,
      deleteBranch: true
    )

    #expect(resolved?.id == "wt-1")
    #expect(request?.worktreeId == "wt-1")
    #expect(request?.force == true)
    #expect(request?.deleteBranch == true)
  }

  @Test func worktreeCleanupBannerStateOnlyAppearsForEndedUndismissedWorktrees() {
    let banner = SessionDetailWorktreeCleanupPlanner.bannerState(
      status: .ended,
      isWorktree: true,
      dismissed: false,
      worktree: makeWorktree(id: "wt-1", path: "/tmp/repo/worktree-a", branch: "feature/a"),
      branch: nil,
      isCleaningUp: false
    )

    #expect(banner?.branchName == "feature/a")
    #expect(banner?.canCleanUp == true)

    #expect(
      SessionDetailWorktreeCleanupPlanner.bannerState(
        status: .active,
        isWorktree: true,
        dismissed: false,
        worktree: makeWorktree(id: "wt-1", path: "/tmp/repo/worktree-a", branch: "feature/a"),
        branch: nil,
        isCleaningUp: false
      ) == nil
    )
  }

  private func makeWorktree(id: String, path: String, branch: String) -> ServerWorktreeSummary {
    ServerWorktreeSummary(
      id: id,
      repoRoot: "/tmp/repo",
      worktreePath: path,
      branch: branch,
      baseBranch: "main",
      status: .active,
      activeSessionCount: 1,
      totalSessionCount: 1,
      createdAt: "2026-03-10T00:00:00Z",
      lastSessionEndedAt: nil,
      diskPresent: true,
      autoPrune: true,
      customName: nil,
      createdBy: .agent
    )
  }

  private func makeTurnDiff(diff: String) -> ServerTurnDiff {
    ServerTurnDiff(
      turnId: "turn-1",
      diff: diff,
      inputTokens: 0,
      outputTokens: 0,
      cachedTokens: 0,
      contextWindow: nil,
      snapshotKind: nil
    )
  }

  private func isDirectFooterMode(_ mode: SessionDetailFooterMode) -> Bool {
    if case .direct = mode { return true }
    return false
  }

  private func isPassiveFooterMode(_ mode: SessionDetailFooterMode) -> Bool {
    if case .passive = mode { return true }
    return false
  }

  private func makeReviewComment(id: String, status: ServerReviewCommentStatus) -> ServerReviewComment {
    ServerReviewComment(
      id: id,
      sessionId: "session-1",
      turnId: nil,
      filePath: "Sources/App.swift",
      lineStart: 10,
      lineEnd: nil,
      body: "comment",
      tag: nil,
      status: status,
      createdAt: "",
      updatedAt: nil
    )
  }
}
