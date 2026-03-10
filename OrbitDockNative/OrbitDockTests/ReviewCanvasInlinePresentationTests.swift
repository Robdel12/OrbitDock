import Foundation
import Testing
@testable import OrbitDock

struct ReviewCanvasInlinePresentationTests {
  @Test func presentationIncludesOpenAndResolvedCommentsForVisibleTurnLine() {
    let comments = [
      makeComment(id: "open-global", filePath: "Sources/A.swift", lineStart: 10, turnId: nil, status: .open),
      makeComment(id: "open-turn", filePath: "Sources/A.swift", lineStart: 10, turnId: "turn-1", status: .open),
      makeComment(id: "ignored-turn", filePath: "Sources/A.swift", lineStart: 10, turnId: "turn-2", status: .open),
    ]

    let presentation = ReviewCanvasInlinePresentationPlanner.presentation(
      comments: comments,
      filePath: "Sources/A.swift",
      newLine: 10,
      activeTurnId: "turn-1",
      resolvedGroups: [10: [makeComment(id: "resolved", filePath: "Sources/A.swift", lineStart: 10, turnId: "turn-1", status: .resolved)]],
      composerTarget: nil,
      fileIndex: 0,
      hunkIndex: 0,
      lineIndex: 4
    )

    #expect(presentation.openComments.map(\.id) == ["open-global", "open-turn"])
    #expect(presentation.resolvedComments.map(\.id) == ["resolved"])
    #expect(presentation.composerContext == nil)
  }

  @Test func presentationBuildsComposerContextOnComposerEndLine() {
    let presentation = ReviewCanvasInlinePresentationPlanner.presentation(
      comments: [],
      filePath: "Sources/A.swift",
      newLine: 20,
      activeTurnId: nil,
      resolvedGroups: [:],
      composerTarget: ReviewComposerLineRange(
        filePath: "Sources/A.swift",
        fileIndex: 0,
        hunkIndex: 1,
        lineStartIdx: 2,
        lineEndIdx: 4,
        lineStart: 20,
        lineEnd: 22
      ),
      fileIndex: 0,
      hunkIndex: 1,
      lineIndex: 4
    )

    #expect(presentation.openComments.isEmpty)
    #expect(presentation.resolvedComments.isEmpty)
    #expect(presentation.composerContext?.fileName == "A.swift")
    #expect(presentation.composerContext?.lineLabel == "Lines 20–22")
  }

  @Test func presentationIgnoresComposerForNonMatchingLine() {
    let presentation = ReviewCanvasInlinePresentationPlanner.presentation(
      comments: [],
      filePath: "Sources/A.swift",
      newLine: nil,
      activeTurnId: nil,
      resolvedGroups: [:],
      composerTarget: ReviewComposerLineRange(
        filePath: "Sources/A.swift",
        fileIndex: 0,
        hunkIndex: 1,
        lineStartIdx: 2,
        lineEndIdx: 4,
        lineStart: 20,
        lineEnd: nil
      ),
      fileIndex: 0,
      hunkIndex: 1,
      lineIndex: 3
    )

    #expect(presentation.openComments.isEmpty)
    #expect(presentation.resolvedComments.isEmpty)
    #expect(presentation.composerContext == nil)
  }

  private func makeComment(
    id: String,
    filePath: String,
    lineStart: UInt32,
    turnId: String?,
    status: ServerReviewCommentStatus
  ) -> ServerReviewComment {
    ServerReviewComment(
      id: id,
      sessionId: "session-1",
      turnId: turnId,
      filePath: filePath,
      lineStart: lineStart,
      lineEnd: nil,
      body: "Needs work",
      tag: nil,
      status: status,
      createdAt: "2026-03-10T00:00:00Z",
      updatedAt: nil
    )
  }
}
