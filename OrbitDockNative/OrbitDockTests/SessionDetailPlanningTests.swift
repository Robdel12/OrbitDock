import Foundation
import Testing
@testable import OrbitDock

struct SessionDetailPlanningTests {
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
}
