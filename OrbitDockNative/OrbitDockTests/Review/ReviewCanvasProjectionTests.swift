import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ReviewCanvasProjectionTests {
  @Test func commentCountsOnlyIncludeOpenCommentsForActiveTurn() {
    let comments = [
      makeComment(id: "global-open", filePath: "Sources/A.swift", lineStart: 10, turnId: nil, status: .open),
      makeComment(id: "turn-open", filePath: "Sources/A.swift", lineStart: 12, turnId: "turn-1", status: .open),
      makeComment(id: "other-turn-open", filePath: "Sources/A.swift", lineStart: 14, turnId: "turn-2", status: .open),
      makeComment(id: "resolved", filePath: "Sources/B.swift", lineStart: 8, turnId: "turn-1", status: .resolved),
    ]

    let result = ReviewCanvasProjection.commentCounts(
      comments: comments,
      activeTurnId: "turn-1"
    )

    #expect(result == ["Sources/A.swift": 2])
  }

  @Test func commentedNewLineNumsIncludesResolvedCommentsOnlyInHistoryMode() {
    let comments = [
      makeComment(id: "open", filePath: "Sources/A.swift", lineStart: 10, lineEnd: 12, status: .open),
      makeComment(id: "resolved", filePath: "Sources/A.swift", lineStart: 20, lineEnd: 21, status: .resolved),
    ]

    let visibleOnlyOpen = ReviewCanvasProjection.commentedNewLineNums(
      comments: comments,
      filePath: "Sources/A.swift",
      activeTurnId: nil,
      showResolvedComments: false
    )
    let visibleWithHistory = ReviewCanvasProjection.commentedNewLineNums(
      comments: comments,
      filePath: "Sources/A.swift",
      activeTurnId: nil,
      showResolvedComments: true
    )

    #expect(visibleOnlyOpen == Set([10, 11, 12]))
    #expect(visibleWithHistory == Set([10, 11, 12, 20, 21]))
  }

  @Test func groupedResolvedCommentsMergesAdjacentResolvedMarkers() {
    let comments = [
      makeComment(id: "r1", filePath: "Sources/A.swift", lineStart: 10, status: .resolved),
      makeComment(id: "r2", filePath: "Sources/A.swift", lineStart: 11, status: .resolved),
      makeComment(id: "r3", filePath: "Sources/A.swift", lineStart: 14, status: .resolved),
    ]

    let result = ReviewCanvasProjection.groupedResolvedComments(
      comments: comments,
      filePath: "Sources/A.swift",
      activeTurnId: nil
    )

    #expect(result.keys.sorted() == [11, 14])
    #expect(result[11]?.map(\.id) == ["r1", "r2"])
    #expect(result[14]?.map(\.id) == ["r3"])
  }

  @Test func sendBarStatePrefersSelectedSubset() {
    let comments = [
      makeComment(id: "c1", filePath: "Sources/A.swift", lineStart: 10, status: .open),
      makeComment(id: "c2", filePath: "Sources/A.swift", lineStart: 12, status: .open),
      makeComment(id: "resolved", filePath: "Sources/A.swift", lineStart: 14, status: .resolved),
    ]

    let result = ReviewCanvasProjection.sendBarState(
      comments: comments,
      selectedCommentIds: ["c2"],
      activeTurnId: nil
    )

    #expect(result?.openCommentCount == 2)
    #expect(result?.selectedCommentCount == 1)
    #expect(result?.sendCount == 1)
    #expect(result?.label == "Send 1 selected")
  }

  @Test func bannerStateAndAddressedStatusTrackPostReviewProgress() {
    let round = ReviewRound(
      sentAt: Date(timeIntervalSince1970: 0),
      turnDiffCountAtSend: 1,
      reviewedFilePaths: ["Sources/A.swift", "Sources/B.swift"],
      commentCount: 3
    )
    let turnDiffs = [
      ServerTurnDiff(turnId: "t0", diff: diff(for: "Sources/Unrelated.swift")),
      ServerTurnDiff(turnId: "t1", diff: diff(for: "Sources/B.swift")),
    ]

    let banner = ReviewCanvasProjection.bannerState(
      lastReviewRound: round,
      showReviewBanner: true,
      turnDiffs: turnDiffs
    )
    let addressedA = ReviewCanvasProjection.addressedFileStatus(
      filePath: "Sources/A.swift",
      lastReviewRound: round,
      turnDiffs: turnDiffs
    )
    let addressedB = ReviewCanvasProjection.addressedFileStatus(
      filePath: "Sources/B.swift",
      lastReviewRound: round,
      turnDiffs: turnDiffs
    )
    let notReviewed = ReviewCanvasProjection.addressedFileStatus(
      filePath: "Sources/C.swift",
      lastReviewRound: round,
      turnDiffs: turnDiffs
    )

    #expect(banner?.tone == .progress)
    #expect(banner?.iconName == "arrow.triangle.2.circlepath")
    #expect(banner?.title == "1 of 2 reviewed files updated")
    #expect(addressedA == false)
    #expect(addressedB == true)
    #expect(notReviewed == nil)
  }

  private func makeComment(
    id: String,
    filePath: String,
    lineStart: UInt32,
    lineEnd: UInt32? = nil,
    turnId: String? = nil,
    status: ServerReviewCommentStatus = .open
  ) -> ServerReviewComment {
    ServerReviewComment(
      id: id,
      sessionId: "session-1",
      turnId: turnId,
      filePath: filePath,
      lineStart: lineStart,
      lineEnd: lineEnd,
      body: "Needs work",
      tag: nil,
      status: status,
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
