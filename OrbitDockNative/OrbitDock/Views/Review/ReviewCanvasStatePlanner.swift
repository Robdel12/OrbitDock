import Foundation

enum ReviewCanvasStatePlanner {
  static func rawDiff(
    selectedTurnDiffId: String?,
    turnDiffs: [ServerTurnDiff],
    currentDiff: String?
  ) -> String? {
    if let selectedTurnDiffId {
      return turnDiffs.first(where: { $0.turnId == selectedTurnDiffId })?.diff
    }

    var parts: [String] = turnDiffs.map(\.diff)
    if let currentDiff, !currentDiff.isEmpty, turnDiffs.last?.diff != currentDiff {
      parts.append(currentDiff)
    }

    let combined = parts.joined(separator: "\n")
    return combined.isEmpty ? nil : combined
  }

  static func refreshState(
    cursorIndex: Int,
    previousFileCount: Int,
    isFollowing: Bool,
    isSessionActive: Bool,
    newFileCount: Int,
    targets: [ReviewCursorTarget]
  ) -> ReviewCanvasRefreshState {
    var nextCursorIndex = ReviewCursorNavigation.clampedCursorIndex(
      cursorIndex: cursorIndex,
      targets: targets
    )

    if let followIndex = ReviewCursorNavigation.autoFollowFileHeaderIndex(
      isFollowing: isFollowing,
      isSessionActive: isSessionActive,
      previousFileCount: previousFileCount,
      newFileCount: newFileCount,
      targets: targets
    ) {
      nextCursorIndex = followIndex
    }

    return ReviewCanvasRefreshState(
      cursorIndex: nextCursorIndex,
      previousFileCount: newFileCount
    )
  }

  static func shouldLoadReviewComments(existingComments: [ServerReviewComment]) -> Bool {
    existingComments.isEmpty
  }
}
