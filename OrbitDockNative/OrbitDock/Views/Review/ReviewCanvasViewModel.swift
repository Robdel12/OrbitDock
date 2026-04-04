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

  @ObservationIgnored private var sessionObservationGeneration: UInt64 = 0
  @ObservationIgnored private var hydratedTurnCount: UInt64 = 0
  @ObservationIgnored private var pendingHydrationTurnCount: UInt64 = 0
  @ObservationIgnored private var isHydratingDiffs = false

  func bind(sessionId: String, sessionStore: SessionStore) {
    if currentSessionId != sessionId || ObjectIdentifier(currentSessionStore) != ObjectIdentifier(sessionStore) {
      resetDiffState()
    }
    currentSessionId = sessionId
    currentSessionStore = sessionStore
    sessionObservationGeneration &+= 1
    startObservation(generation: sessionObservationGeneration)
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
    Task {
      try? await currentSessionStore.listReviewComments(sessionId: currentSessionId, turnId: nil)
    }
  }

  func loadDiffsIfNeeded() {
    guard !currentSessionId.isEmpty else { return }
    let session = currentSessionStore.session(currentSessionId)
    pendingHydrationTurnCount = max(pendingHydrationTurnCount, session.turnCount)
    guard session.workStatus != .working else { return }
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

  private func startObservation(generation: UInt64) {
    guard !currentSessionId.isEmpty else {
      apply(snapshot: .empty)
      return
    }

    let sessionId = currentSessionId
    let sessionStore = currentSessionStore

    withObservationTracking {
      let session = sessionStore.session(sessionId)
      let snapshot = ReviewCanvasSnapshot(
        turnCount: session.turnCount,
        isWorking: session.workStatus == .working,
        reviewComments: session.reviewComments
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
    reviewComments = snapshot.reviewComments

    if snapshot.turnCount == 0 {
      resetDiffState()
      return
    }

    if snapshot.turnCount > hydratedTurnCount {
      pendingHydrationTurnCount = max(pendingHydrationTurnCount, snapshot.turnCount)
    }

    guard !snapshot.isWorking else { return }
    hydrateDiffsIfNeeded()
  }

  private func hydrateDiffsIfNeeded() {
    guard !currentSessionId.isEmpty else { return }
    guard pendingHydrationTurnCount > hydratedTurnCount else { return }
    guard !isHydratingDiffs else { return }

    let targetTurnCount = pendingHydrationTurnCount
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
        self.hydratedTurnCount = max(self.hydratedTurnCount, targetTurnCount)
      } catch {
        return
      }

      if self.pendingHydrationTurnCount > self.hydratedTurnCount {
        self.hydrateDiffsIfNeeded()
      }
    }
  }

  private func resetDiffState() {
    turnDiffs = []
    currentDiff = nil
    cumulativeDiff = nil
    hydratedTurnCount = 0
    pendingHydrationTurnCount = 0
    isHydratingDiffs = false
  }
}

private struct ReviewCanvasSnapshot {
  let turnCount: UInt64
  let isWorking: Bool
  let reviewComments: [ServerReviewComment]

  static let empty = ReviewCanvasSnapshot(
    turnCount: 0,
    isWorking: false,
    reviewComments: []
  )
}
