import Foundation
@testable import OrbitDock
import Testing

struct ReviewWorkflowTests {
  @Test func commentsToSendPrefersSelectedSubsetWhenPresent() {
    let comments = [
      makeComment(id: "c1", filePath: "Sources/A.swift"),
      makeComment(id: "c2", filePath: "Sources/B.swift"),
    ]

    let result = ReviewWorkflow.commentsToSend(
      openComments: comments,
      selectedCommentIds: ["c2"]
    )

    #expect(result.map(\.id) == ["c2"])
  }

  @Test func commentsToSendFallsBackToAllOpenComments() {
    let comments = [
      makeComment(id: "c1", filePath: "Sources/A.swift"),
      makeComment(id: "c2", filePath: "Sources/B.swift"),
    ]

    let result = ReviewWorkflow.commentsToSend(
      openComments: comments,
      selectedCommentIds: []
    )

    #expect(result.map(\.id) == ["c1", "c2"])
  }

  @Test func addressedFilePathsOnlyIncludesReviewedFilesTouchedAfterSend() {
    let result = ReviewWorkflow.addressedFilePaths(
      reviewedFilePaths: ["Sources/A.swift", "Sources/B.swift"],
      turnDiffCountAtSend: 1,
      turnDiffs: [
        ServerTurnDiff(turnId: "t0", diff: diff(for: "Sources/A.swift")),
        ServerTurnDiff(turnId: "t1", diff: diff(for: "Sources/C.swift")),
        ServerTurnDiff(turnId: "t2", diff: diff(for: "Sources/B.swift")),
      ]
    )

    #expect(result == ["Sources/B.swift"])
  }

  @Test func hasPostReviewChangesTracksNewTurnDiffsAfterReviewRound() {
    #expect(
      ReviewWorkflow.hasPostReviewChanges(
        turnDiffCountAtSend: 2,
        turnDiffs: [
          ServerTurnDiff(turnId: "t0", diff: diff(for: "Sources/A.swift")),
          ServerTurnDiff(turnId: "t1", diff: diff(for: "Sources/B.swift")),
          ServerTurnDiff(turnId: "t2", diff: diff(for: "Sources/C.swift")),
        ]
      ) == true
    )

    #expect(
      ReviewWorkflow.hasPostReviewChanges(
        turnDiffCountAtSend: 3,
        turnDiffs: [
          ServerTurnDiff(turnId: "t0", diff: diff(for: "Sources/A.swift")),
          ServerTurnDiff(turnId: "t1", diff: diff(for: "Sources/B.swift")),
          ServerTurnDiff(turnId: "t2", diff: diff(for: "Sources/C.swift")),
        ]
      ) == false
    )
  }

  private func makeComment(id: String, filePath: String) -> ServerReviewComment {
    ServerReviewComment(
      id: id,
      sessionId: "session-1",
      turnId: nil,
      filePath: filePath,
      lineStart: 10,
      lineEnd: nil,
      body: "Needs work",
      tag: nil,
      status: .open,
      createdAt: "2026-03-10T00:00:00Z",
      updatedAt: nil
    )
  }

  private func diff(for filePath: String) -> String {
    """
    --- a/\(filePath)
    +++ b/\(filePath)
    @@ -1,1 +1,1 @@
    -old
    +new
    """
  }
}
