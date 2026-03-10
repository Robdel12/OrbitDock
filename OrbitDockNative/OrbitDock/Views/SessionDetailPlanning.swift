import Foundation

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

struct SessionDetailReviewNavigationPlan {
  let reviewFileId: String
  let navigateToComment: ServerReviewComment?
  let layoutConfig: LayoutConfiguration
}

enum SessionDetailLayoutPlanner {
  static func nextLayout(
    currentLayout: LayoutConfiguration,
    intent: SessionDetailLayoutIntent
  ) -> LayoutConfiguration {
    switch intent {
      case .toggleSplitShortcut:
        return currentLayout == .conversationOnly ? .split : .conversationOnly
      case .showReviewOnlyShortcut:
        return .reviewOnly
      case .dismissReview:
        return .conversationOnly
      case .revealReviewSplit:
        return currentLayout == .conversationOnly ? .split : currentLayout
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

struct SessionDetailWorktreeCleanupBannerState: Equatable {
  let branchName: String
  let canCleanUp: Bool
}

struct SessionDetailWorktreeCleanupRequest: Equatable {
  let worktreeId: String
  let force: Bool
  let deleteBranch: Bool
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
