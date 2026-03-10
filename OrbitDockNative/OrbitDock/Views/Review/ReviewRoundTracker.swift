import Foundation

struct ReviewRoundTrackerState: Equatable {
  var lastRound: ReviewRound?
  var isBannerVisible = true

  var reviewedFilePaths: Set<String> {
    lastRound?.reviewedFilePaths ?? []
  }

  mutating func record(_ round: ReviewRound) {
    lastRound = round
    isBannerVisible = true
  }

  mutating func dismissBanner() {
    isBannerVisible = false
  }
}

enum ReviewRoundTracker {
  static func addressedFilePaths(
    state: ReviewRoundTrackerState,
    turnDiffs: [ServerTurnDiff]
  ) -> Set<String> {
    guard let round = state.lastRound else { return [] }
    return ReviewWorkflow.addressedFilePaths(
      reviewedFilePaths: round.reviewedFilePaths,
      turnDiffCountAtSend: round.turnDiffCountAtSend,
      turnDiffs: turnDiffs
    )
  }

  static func addressedFileStatus(
    filePath: String,
    state: ReviewRoundTrackerState,
    turnDiffs: [ServerTurnDiff]
  ) -> Bool? {
    guard let round = state.lastRound else { return nil }
    guard round.reviewedFilePaths.contains(filePath) else { return nil }
    return addressedFilePaths(state: state, turnDiffs: turnDiffs).contains(filePath)
  }

  static func bannerState(
    state: ReviewRoundTrackerState,
    turnDiffs: [ServerTurnDiff]
  ) -> ReviewBannerState? {
    guard state.isBannerVisible, let round = state.lastRound else { return nil }

    let addressed = addressedFilePaths(state: state, turnDiffs: turnDiffs)
    let hasChanges = ReviewWorkflow.hasPostReviewChanges(
      turnDiffCountAtSend: round.turnDiffCountAtSend,
      turnDiffs: turnDiffs
    )

    if hasChanges {
      let total = round.reviewedFilePaths.count
      return ReviewBannerState(
        tone: .progress,
        iconName: addressed.count == total ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
        title: "\(addressed.count) of \(total) reviewed file\(total == 1 ? "" : "s") updated",
        detail: nil
      )
    }

    let fileCount = round.reviewedFilePaths.count
    return ReviewBannerState(
      tone: .pending,
      iconName: "paperplane.fill",
      title: "Review sent",
      detail: "\(round.commentCount) comment\(round.commentCount == 1 ? "" : "s") on \(fileCount) file\(fileCount == 1 ? "" : "s")"
    )
  }
}
