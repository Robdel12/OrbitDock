import Foundation
@testable import OrbitDock
import Testing

struct ReviewCanvasStatePlannerTests {
  @Test func rawDiffPrefersSelectedTurnDiff() {
    let result = ReviewCanvasStatePlanner.rawDiff(
      selectedTurnDiffId: "turn-2",
      turnDiffs: [
        ServerTurnDiff(turnId: "turn-1", diff: "diff-1"),
        ServerTurnDiff(turnId: "turn-2", diff: "diff-2"),
      ],
      currentDiff: "current"
    )

    #expect(result == "diff-2")
  }

  @Test func rawDiffBuildsCumulativeDiffWithoutDuplicatingCurrentTail() {
    let withDistinctCurrent = ReviewCanvasStatePlanner.rawDiff(
      selectedTurnDiffId: nil,
      turnDiffs: [
        ServerTurnDiff(turnId: "turn-1", diff: "diff-1"),
        ServerTurnDiff(turnId: "turn-2", diff: "diff-2"),
      ],
      currentDiff: "diff-3"
    )
    let withMatchingTail = ReviewCanvasStatePlanner.rawDiff(
      selectedTurnDiffId: nil,
      turnDiffs: [
        ServerTurnDiff(turnId: "turn-1", diff: "diff-1"),
        ServerTurnDiff(turnId: "turn-2", diff: "diff-2"),
      ],
      currentDiff: "diff-2"
    )

    #expect(withDistinctCurrent == "diff-1\ndiff-2\ndiff-3")
    #expect(withMatchingTail == "diff-1\ndiff-2")
  }

  @Test func refreshStateAutoFollowsNewestFileHeaderWhenActiveAndFollowing() {
    let result = ReviewCanvasStatePlanner.refreshState(
      cursorIndex: 0,
      previousFileCount: 1,
      isFollowing: true,
      isSessionActive: true,
      newFileCount: 2,
      targets: [
        .fileHeader(fileIndex: 0),
        .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 0),
        .fileHeader(fileIndex: 1),
      ]
    )

    #expect(result.cursorIndex == 2)
    #expect(result.previousFileCount == 2)
  }

  @Test func refreshStateOnlyClampsCursorWhenFollowConditionsAreNotMet() {
    let result = ReviewCanvasStatePlanner.refreshState(
      cursorIndex: 9,
      previousFileCount: 2,
      isFollowing: false,
      isSessionActive: true,
      newFileCount: 2,
      targets: [
        .fileHeader(fileIndex: 0),
        .fileHeader(fileIndex: 1),
      ]
    )

    #expect(result.cursorIndex == 1)
    #expect(result.previousFileCount == 2)
  }

  @Test func shouldLoadReviewCommentsOnlyWhenCanvasHasNoCommentsYet() {
    #expect(ReviewCanvasStatePlanner.shouldLoadReviewComments(existingComments: []) == true)
    #expect(ReviewCanvasStatePlanner.shouldLoadReviewComments(existingComments: [makeComment(id: "c1")]) == false)
  }

  private func makeComment(id: String) -> ServerReviewComment {
    ServerReviewComment(
      id: id,
      sessionId: "session-1",
      turnId: nil,
      filePath: "Sources/A.swift",
      lineStart: 10,
      lineEnd: nil,
      body: "Needs work",
      tag: nil,
      status: .open,
      createdAt: "2026-03-10T00:00:00Z",
      updatedAt: nil
    )
  }
}
