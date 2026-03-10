import SwiftUI

extension SessionDetailView {
  func openPendingApprovalPanel() {
    let nextState = SessionDetailConversationChromePlanner.openPendingApprovalPanel(
      current: conversationChromeState
    )
    applyConversationChromeState(nextState, animatePendingApprovalPanel: true)
  }

  func jumpConversationToLatest() {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.jumpToLatest(current: conversationChromeState)
    )
  }

  func toggleConversationPinnedState() {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.togglePinned(current: conversationChromeState)
    )
  }

  func cleanUpWorktree() {
    guard let request = SessionDetailWorktreeCleanupPlanner.cleanupRequest(
      worktree: worktreeForSession,
      deleteBranch: deleteBranchOnCleanup
    ) else {
      return
    }
    isCleaningUpWorktree = true
    worktreeCleanupError = nil

    Task {
      do {
        try await scopedServerState.clients.worktrees.removeWorktree(
          worktreeId: request.worktreeId,
          force: request.force,
          deleteBranch: request.deleteBranch
        )
        withAnimation(Motion.gentle) {
          worktreeCleanupDismissed = true
        }
      } catch {
        worktreeCleanupError = error.localizedDescription
      }
      isCleaningUpWorktree = false
    }
  }

  func copyResumeCommand() {
    let command = "claude --resume \(sessionId)"
    Platform.services.copyToClipboard(command)
    copiedResume = true

    Task {
      try? await Task.sleep(for: .seconds(2))
      await MainActor.run {
        copiedResume = false
      }
    }
  }

  func endDirectSession() {
    Task { try? await scopedServerState.endSession(sessionId) }
  }

  func sendReviewToModel() {
    guard let plan = SessionDetailReviewSendPlanner.makePlan(
      reviewComments: obs.reviewComments,
      selectedCommentIds: selectedCommentIds,
      turnDiffs: obs.turnDiffs,
      currentDiff: obs.diff
    ) else {
      return
    }

    Task {
      try? await scopedServerState.sendMessage(sessionId: sessionId, content: plan.message)

      for commentId in plan.commentIdsToResolve {
        try? await scopedServerState.clients.approvals.updateReviewComment(
          commentId: commentId,
          body: ApprovalsClient.UpdateReviewCommentRequest(status: .resolved)
        )
      }
    }

    selectedCommentIds.removeAll()
  }
}
