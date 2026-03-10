import Foundation

enum ReviewWorkflow {
  static func commentsToSend(
    openComments: [ServerReviewComment],
    selectedCommentIds: Set<String>
  ) -> [ServerReviewComment] {
    guard !selectedCommentIds.isEmpty else { return openComments }
    return openComments.filter { selectedCommentIds.contains($0.id) }
  }

  static func reviewedFilePaths(for comments: [ServerReviewComment]) -> Set<String> {
    Set(comments.map(\.filePath))
  }

  static func hasPostReviewChanges(
    turnDiffCountAtSend: Int,
    turnDiffs: [ServerTurnDiff]
  ) -> Bool {
    turnDiffs.count > turnDiffCountAtSend
  }

  static func addressedFilePaths(
    reviewedFilePaths: Set<String>,
    turnDiffCountAtSend: Int,
    turnDiffs: [ServerTurnDiff]
  ) -> Set<String> {
    guard !reviewedFilePaths.isEmpty else { return [] }

    let postReviewDiffs = Array(turnDiffs.dropFirst(turnDiffCountAtSend))
    guard !postReviewDiffs.isEmpty else { return [] }

    var addressed = Set<String>()
    for turnDiff in postReviewDiffs {
      for path in reviewedFilePaths where diffMentionsFile(turnDiff.diff, filePath: path) {
        addressed.insert(path)
      }
    }
    return addressed
  }

  static func diffMentionsFile(_ diff: String, filePath: String) -> Bool {
    diff.contains("+++ b/\(filePath)") || diff.contains("--- a/\(filePath)")
  }
}
