import Foundation

struct ReviewSendPlan: Equatable {
  let message: String
  let reviewRound: ReviewRound
  let commentIdsToResolve: [String]
}

enum ReviewSendCoordinator {
  static func makePlan(
    openComments: [ServerReviewComment],
    selectedCommentIds: Set<String>,
    diffModel: DiffModel?,
    turnDiffs: [ServerTurnDiff],
    sentAt: Date = Date()
  ) -> ReviewSendPlan? {
    guard !openComments.isEmpty else { return nil }

    let commentsToSend = ReviewWorkflow.commentsToSend(
      openComments: openComments,
      selectedCommentIds: selectedCommentIds
    )
    guard !commentsToSend.isEmpty else { return nil }

    guard let message = ReviewMessageFormatter.format(comments: commentsToSend, model: diffModel) else {
      return nil
    }

    let reviewedFiles = ReviewWorkflow.reviewedFilePaths(for: commentsToSend)
    let reviewRound = ReviewRound(
      sentAt: sentAt,
      turnDiffCountAtSend: turnDiffs.count,
      reviewedFilePaths: reviewedFiles,
      commentCount: commentsToSend.count
    )

    return ReviewSendPlan(
      message: message,
      reviewRound: reviewRound,
      commentIdsToResolve: commentsToSend.map(\.id)
    )
  }
}
