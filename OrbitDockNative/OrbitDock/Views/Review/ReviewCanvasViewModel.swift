import Observation
import SwiftUI

@MainActor
@Observable
final class ReviewCanvasViewModel {
  var currentSessionId = ""
  var currentSessionStore = SessionStore.preview()
  var turnDiffs: [ServerTurnDiff] = []
  var currentDiff: String?
  var reviewComments: [ServerReviewComment] = []

  @ObservationIgnored private var sessionObservationGeneration: UInt64 = 0

  func bind(sessionId: String, sessionStore: SessionStore) {
    currentSessionId = sessionId
    currentSessionStore = sessionStore
    sessionObservationGeneration &+= 1
    startObservation(generation: sessionObservationGeneration)
  }

  func rawDiff(selectedTurnDiffId: String?) -> String? {
    ReviewCanvasStatePlanner.rawDiff(
      selectedTurnDiffId: selectedTurnDiffId,
      turnDiffs: turnDiffs,
      currentDiff: currentDiff
    )
  }

  func loadReviewCommentsIfNeeded() {
    guard ReviewCanvasStatePlanner.shouldLoadReviewComments(existingComments: reviewComments) else { return }
    Task {
      try? await currentSessionStore.listReviewComments(sessionId: currentSessionId, turnId: nil)
    }
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

  private func startObservation(generation: UInt64) {
    guard !currentSessionId.isEmpty else {
      apply(snapshot: .empty)
      return
    }

    let sessionId = currentSessionId
    let sessionStore = currentSessionStore

    withObservationTracking {
      let snapshot = ReviewCanvasSnapshot(
        turnDiffs: sessionStore.session(sessionId).turnDiffs,
        currentDiff: sessionStore.session(sessionId).diff,
        reviewComments: sessionStore.session(sessionId).reviewComments
      )
      apply(snapshot: snapshot)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.sessionObservationGeneration == generation else { return }
        self.startObservation(generation: generation)
      }
    }
  }

  private func apply(snapshot: ReviewCanvasSnapshot) {
    turnDiffs = snapshot.turnDiffs
    currentDiff = snapshot.currentDiff
    reviewComments = snapshot.reviewComments
  }
}

private struct ReviewCanvasSnapshot {
  let turnDiffs: [ServerTurnDiff]
  let currentDiff: String?
  let reviewComments: [ServerReviewComment]

  static let empty = ReviewCanvasSnapshot(
    turnDiffs: [],
    currentDiff: nil,
    reviewComments: []
  )
}
