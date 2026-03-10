import Foundation

struct SessionDetailReviewSendPlan: Equatable {
  let message: String
  let commentIdsToResolve: [String]
}

enum SessionDetailReviewSendPlanner {
  static func makePlan(
    reviewComments: [ServerReviewComment],
    selectedCommentIds: Set<String>,
    turnDiffs: [ServerTurnDiff],
    currentDiff: String?
  ) -> SessionDetailReviewSendPlan? {
    let openComments = reviewComments.filter { $0.status == .open }
    guard !openComments.isEmpty else { return nil }

    let commentsToSend = ReviewWorkflow.commentsToSend(
      openComments: openComments,
      selectedCommentIds: selectedCommentIds
    )
    guard !commentsToSend.isEmpty else { return nil }

    let diffModel = makeDiffModel(turnDiffs: turnDiffs, currentDiff: currentDiff)
    guard let message = ReviewMessageFormatter.format(comments: commentsToSend, model: diffModel) else {
      return nil
    }

    return SessionDetailReviewSendPlan(
      message: message,
      commentIdsToResolve: commentsToSend.map(\.id)
    )
  }

  static func makeDiffModel(
    turnDiffs: [ServerTurnDiff],
    currentDiff: String?
  ) -> DiffModel? {
    let cumulativeDiffParts = turnDiffs.map(\.diff)
    let allDiffParts =
      if let currentDiff, !currentDiff.isEmpty, turnDiffs.last?.diff != currentDiff {
        cumulativeDiffParts + [currentDiff]
      } else {
        cumulativeDiffParts
      }

    let combinedDiff = allDiffParts.joined(separator: "\n")
    return combinedDiff.isEmpty ? nil : DiffModel.parse(unifiedDiff: combinedDiff)
  }
}
