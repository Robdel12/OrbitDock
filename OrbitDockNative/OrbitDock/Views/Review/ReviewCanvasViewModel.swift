import Observation
import SwiftUI

@MainActor
@Observable
final class ReviewCanvasViewModel {
  private struct BindingContext {
    let sessionId: String
    let session: ServerSessionContext
    let revision: Int
  }

  var currentSessionId = ""
  var currentSession: ServerSessionContext
  var turnDiffs: [ServerTurnDiff] = []
  var currentDiff: String?
  var cumulativeDiff: String?
  var reviewComments: [ServerReviewComment] = []

  @ObservationIgnored private let refreshRunner = CoalescedRefreshRunner()
  @ObservationIgnored private var currentBindingRevision = 0
  @ObservationIgnored private var activeSubscriptionIdentity: String?
  @ObservationIgnored private var activeSubscriptionSession: ServerSessionContext?
  @ObservationIgnored private var pendingInvalidationRevision: UInt64?
  @ObservationIgnored private var lastLoadedRevision: UInt64?

  init(
    sessionId: String,
    session: ServerSessionContext
  ) {
    currentSessionId = sessionId
    currentSession = session
  }

  convenience init() {
    self.init(
      sessionId: "",
      session: ServerSessionContext.preview()
    )
  }

  func bind(sessionId: String, session: ServerSessionContext) {
    if currentSessionId != sessionId || ObjectIdentifier(currentSession) != ObjectIdentifier(session) {
      currentBindingRevision += 1
      refreshRunner.cancel()
      pendingInvalidationRevision = nil
      lastLoadedRevision = nil
      resetDiffState()
      clearSessionSubscription()
    }
    currentSessionId = sessionId
    currentSession = session
  }

  func runLifecycle(
    bindingIdentity: String,
    sessionId: String,
    session: ServerSessionContext
  ) async {
    let (stream, listenerId) = session.transport.events()
    defer {
      session.transport.removeEventListener(id: listenerId)
      clearSessionSubscription()
    }

    bind(sessionId: sessionId, session: session)
    reconcileSessionSubscription(bindingIdentity: bindingIdentity)
    await refresh()

    for await event in stream {
      guard !Task.isCancelled else { break }
      guard event.invalidates(.review) else { continue }
      let invalidationRevision = session.transport.latestRevision
      guard SessionSurfaceRefreshPlanner.shouldRequestRefresh(
        snapshotRevision: lastLoadedRevision,
        pendingRevision: pendingInvalidationRevision,
        incomingInvalidationRevision: invalidationRevision
      ) else { continue }
      pendingInvalidationRevision = SessionSurfaceRefreshPlanner.nextPendingRevision(
        pendingRevision: pendingInvalidationRevision,
        incomingInvalidationRevision: invalidationRevision
      )
      requestRefresh()
    }
  }

  func refresh() async {
    requestRefresh()
    await refreshRunner.waitForCurrentRefresh()
  }

  func requestRefresh() {
    refreshRunner.schedule { [weak self] in
      await self?.performRefresh()
    }
  }

  func rawDiff(selectedTurnDiffId: String?) -> String? {
    ReviewCanvasStatePlanner.rawDiff(
      selectedTurnDiffId: selectedTurnDiffId,
      turnDiffs: turnDiffs,
      currentDiff: currentDiff,
      cumulativeDiff: cumulativeDiff
    )
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
      try? await currentSession.api.sendMessage(content: plan.message)
    }

    for commentId in plan.commentIdsToResolve {
      updateCommentStatus(commentId: commentId, status: .resolved)
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
      guard let mutation = try? await currentSession.api.createReviewComment(
        request: ApprovalsClient.CreateReviewCommentRequest(
          turnId: turnId,
          filePath: filePath,
          lineStart: lineStart,
          lineEnd: lineEnd,
          body: body,
          tag: tag
        )
      ) else { return }
      applyReviewCommentMutation(mutation)
    }
  }

  func updateCommentStatus(commentId: String, status: ServerReviewCommentStatus) {
    Task {
      guard let mutation = try? await currentSession.api.updateReviewComment(
        commentId: commentId,
        body: ApprovalsClient.UpdateReviewCommentRequest(status: status)
      ) else { return }
      applyReviewCommentMutation(mutation)
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

  private func resetDiffState() {
    turnDiffs = []
    currentDiff = nil
    cumulativeDiff = nil
    reviewComments = []
  }

  private func applyReviewCommentMutation(
    _ mutation: ApprovalsClient.ReviewCommentMutationResponse
  ) {
    guard mutation.sessionId == currentSessionId else { return }
    currentSession.transport.recordRevision(mutation.reviewRevision)
    lastLoadedRevision = max(lastLoadedRevision ?? mutation.reviewRevision, mutation.reviewRevision)

    if mutation.deleted {
      reviewComments.removeAll { $0.id == mutation.commentId }
      return
    }

    guard let comment = mutation.comment else { return }
    if let existingIndex = reviewComments.firstIndex(where: { $0.id == comment.id }) {
      reviewComments[existingIndex] = comment
    } else {
      reviewComments.append(comment)
    }
  }

  func applyReviewSnapshotPayload(_ payload: ServerSessionReviewSnapshotPayload) {
    if let lastLoadedRevision, payload.revision < lastLoadedRevision {
      return
    }
    currentSession.transport.recordRevision(payload.revision)
    lastLoadedRevision = max(lastLoadedRevision ?? payload.revision, payload.revision)
    if let pendingInvalidationRevision, pendingInvalidationRevision <= payload.revision {
      self.pendingInvalidationRevision = nil
    }
    reviewComments = payload.comments
    turnDiffs = payload.turnDiffs
    currentDiff = payload.currentDiff
    cumulativeDiff = payload.cumulativeDiff
  }

  private var currentBindingContext: BindingContext? {
    guard !currentSessionId.isEmpty else { return nil }
    return BindingContext(
      sessionId: currentSessionId,
      session: currentSession,
      revision: currentBindingRevision
    )
  }

  private func isCurrent(_ binding: BindingContext) -> Bool {
    currentSessionId == binding.sessionId
      && currentSession === binding.session
      && currentBindingRevision == binding.revision
  }

  private func performRefresh() async {
    guard let binding = currentBindingContext else {
      resetDiffState()
      return
    }
    if let pendingInvalidationRevision,
       let lastLoadedRevision,
       pendingInvalidationRevision <= lastLoadedRevision
    {
      self.pendingInvalidationRevision = nil
      return
    }

    if let payload = try? await binding.session.api.fetchReviewSnapshot() {
      guard isCurrent(binding) else { return }
      applyReviewSnapshotPayload(payload)
    } else {
      pendingInvalidationRevision = nil
    }
  }

  private func reconcileSessionSubscription(bindingIdentity: String) {
    guard !currentSessionId.isEmpty else {
      clearSessionSubscription()
      return
    }
    guard activeSubscriptionIdentity != bindingIdentity else { return }
    clearSessionSubscription()
    currentSession.transport.subscribe(surfaces: [.review])
    activeSubscriptionIdentity = bindingIdentity
    activeSubscriptionSession = currentSession
  }

  private func clearSessionSubscription() {
    refreshRunner.cancel()
    pendingInvalidationRevision = nil
    activeSubscriptionSession?.transport.unsubscribe(surfaces: [.review])
    activeSubscriptionSession = nil
    activeSubscriptionIdentity = nil
  }
}
