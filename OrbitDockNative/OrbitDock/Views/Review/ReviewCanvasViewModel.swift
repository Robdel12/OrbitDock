import Observation
import SwiftUI

@MainActor
@Observable
final class ReviewCanvasViewModel {
  var currentSessionId = ""
  var currentSessionStore = SessionStore.preview()
  var turnDiffs: [ServerTurnDiff] = []
  var currentDiff: String?
  var cumulativeDiff: String?
  var reviewComments: [ServerReviewComment] = []

  @ObservationIgnored private var isHydratingDiffs = false
  @ObservationIgnored private var isRefreshing = false
  @ObservationIgnored private var refreshQueued = false

  func bind(sessionId: String, sessionStore: SessionStore) {
    if currentSessionId != sessionId || ObjectIdentifier(currentSessionStore) != ObjectIdentifier(sessionStore) {
      resetDiffState()
    }
    currentSessionId = sessionId
    currentSessionStore = sessionStore
  }

  func refresh() async {
    guard !currentSessionId.isEmpty else {
      resetDiffState()
      return
    }

    if isRefreshing {
      refreshQueued = true
      return
    }

    isRefreshing = true
    refreshQueued = false
    defer {
      isRefreshing = false
      if refreshQueued {
        refreshQueued = false
        Task { await refresh() }
      }
    }

    // Load review comments via HTTP
    do {
      let response = try await currentSessionStore.clients.approvals.listReviewComments(
        sessionId: currentSessionId, turnId: nil
      )
      reviewComments = response.comments
    } catch {
      // Non-fatal
    }

    // Hydrate diffs if the session has new turns
    hydrateDiffsIfNeeded()
  }

  func rawDiff(selectedTurnDiffId: String?) -> String? {
    ReviewCanvasStatePlanner.rawDiff(
      selectedTurnDiffId: selectedTurnDiffId,
      turnDiffs: turnDiffs,
      currentDiff: currentDiff,
      cumulativeDiff: cumulativeDiff
    )
  }

  func loadReviewCommentsIfNeeded() {
    guard ReviewCanvasStatePlanner.shouldLoadReviewComments(existingComments: reviewComments) else { return }
    Task { await refresh() }
  }

  func loadDiffsIfNeeded() {
    hydrateDiffsIfNeeded()
  }

  func sendReview(
    selectedCommentIds: inout Set<String>,
    selectedTurnDiffId: String?,
    diffModel: DiffModel?,
    reviewRoundTracker: inout ReviewRoundTrackerState
  ) {
    let openComments = ReviewCanvasProjection.openComments(
      from: reviewComments,
      activeTurnId: selectedTurnDiffId
    )

    guard let plan = ReviewSendCoordinator.makePlan(
      openComments: openComments,
      selectedCommentIds: selectedCommentIds,
      diffModel: diffModel,
      turnDiffs: turnDiffs
    ) else { return }

    reviewRoundTracker.record(plan.reviewRound)

    Task {
      try? await currentSessionStore.sendMessage(sessionId: currentSessionId, content: plan.message)
    }

    for commentId in plan.commentIdsToResolve {
      Task {
        try? await currentSessionStore.clients.approvals.updateReviewComment(
          commentId: commentId,
          body: ApprovalsClient.UpdateReviewCommentRequest(status: .resolved)
        )
      }
    }

    selectedCommentIds.removeAll()
  }

  func createReviewComment(
    turnId: String?,
    filePath: String,
    lineStart: UInt32,
    lineEnd: UInt32?,
    body: String,
    tag: ServerReviewCommentTag?
  ) {
    Task {
      _ = try? await currentSessionStore.clients.approvals.createReviewComment(
        sessionId: currentSessionId,
        request: ApprovalsClient.CreateReviewCommentRequest(
          turnId: turnId,
          filePath: filePath,
          lineStart: lineStart,
          lineEnd: lineEnd,
          body: body,
          tag: tag
        )
      )
    }
  }

  func updateCommentStatus(commentId: String, status: ServerReviewCommentStatus) {
    Task {
      try? await currentSessionStore.clients.approvals.updateReviewComment(
        commentId: commentId,
        body: ApprovalsClient.UpdateReviewCommentRequest(status: status)
      )
    }
  }

  func inferTurnId(forFile filePath: String) -> String? {
    for turnDiff in turnDiffs.reversed() {
      if ReviewWorkflow.diffMentionsFile(turnDiff.diff, filePath: filePath) {
        return turnDiff.turnId
      }
    }
    return nil
  }

  private func hydrateDiffsIfNeeded() {
    guard !currentSessionId.isEmpty else { return }
    guard !isHydratingDiffs else { return }

    let sessionId = currentSessionId
    let sessionStore = currentSessionStore
    isHydratingDiffs = true

    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.isHydratingDiffs = false
      }

      do {
        let payload = try await sessionStore.clients.conversation.fetchSessionDiffs(sessionId)
        guard self.currentSessionId == sessionId else { return }
        self.turnDiffs = payload.turnDiffs
        self.currentDiff = payload.currentDiff
        self.cumulativeDiff = payload.cumulativeDiff
      } catch {
        return
      }
    }
  }

  private func resetDiffState() {
    turnDiffs = []
    currentDiff = nil
    cumulativeDiff = nil
    reviewComments = []
    isHydratingDiffs = false
  }
}
