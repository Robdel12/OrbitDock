import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ReviewCommentComposerPlannerTests {
  @Test func smartCommentTargetSkipsRemovedOnlyLines() {
    let model = makeReviewDiffModel()

    let target = ReviewCommentComposerPlanner.smartCommentTarget(
      fileIndex: 0,
      hunkIndex: 0,
      smartRange: 0 ... 2,
      model: model
    )

    #expect(target?.filePath == "Sources/App.swift")
    #expect(target?.lineStart == 10)
    #expect(target?.lineEnd == 11)
    #expect(target?.lineStartIdx == 0)
    #expect(target?.lineEndIdx == 2)
  }

  @Test func dragCommentTargetRejectsRemovedOnlyRanges() {
    let model = makeReviewDiffModel()

    let target = ReviewCommentComposerPlanner.dragCommentTarget(
      fileIndex: 0,
      hunkIndex: 0,
      startLineIndex: 0,
      endLineIndex: 0,
      model: model
    )

    #expect(target == nil)
  }

  @Test func openComposerTargetBuildsSingleLineCommentFromCursor() {
    let model = makeReviewDiffModel()

    let target = ReviewCommentComposerPlanner.openComposerTarget(
      mark: nil,
      currentTarget: .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 1),
      model: model
    )

    #expect(target == ReviewComposerLineRange(
      filePath: "Sources/App.swift",
      fileIndex: 0,
      hunkIndex: 0,
      lineStartIdx: 1,
      lineEndIdx: 1,
      lineStart: 10,
      lineEnd: Optional(10)
    ))
  }

  @Test func openComposerTargetBuildsRangeCommentFromMarkAndCursor() {
    let model = makeReviewDiffModel()

    let target = ReviewCommentComposerPlanner.openComposerTarget(
      mark: .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 1),
      currentTarget: .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 2),
      model: model
    )

    #expect(target == ReviewComposerLineRange(
      filePath: "Sources/App.swift",
      fileIndex: 0,
      hunkIndex: 0,
      lineStartIdx: 1,
      lineEndIdx: 2,
      lineStart: 10,
      lineEnd: Optional(11)
    ))
  }

  @Test func selectionLineIndicesCoverCrossHunkRanges() {
    let model = makeReviewDiffModel()
    let mark = ReviewCursorTarget.diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 2)
    let current = ReviewCursorTarget.diffLine(fileIndex: 0, hunkIndex: 1, lineIndex: 1)

    let firstHunkSelection = ReviewCommentComposerPlanner.selectionLineIndices(
      mark: mark,
      currentTarget: current,
      model: model,
      fileIndex: 0,
      hunkIndex: 0
    )
    let secondHunkSelection = ReviewCommentComposerPlanner.selectionLineIndices(
      mark: mark,
      currentTarget: current,
      model: model,
      fileIndex: 0,
      hunkIndex: 1
    )

    #expect(firstHunkSelection == [2])
    #expect(secondHunkSelection == [0, 1])
  }

  @Test func canSetMarkRequiresCommentableNewLine() {
    let model = makeReviewDiffModel()

    #expect(ReviewCommentComposerPlanner.canSetMark(
      for: .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 1),
      model: model
    ))
    #expect(!ReviewCommentComposerPlanner.canSetMark(
      for: .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 0),
      model: model
    ))
  }

  private func makeReviewDiffModel() -> DiffModel {
    DiffModel(files: [
      FileDiff(
        id: "Sources/App.swift",
        oldPath: "Sources/App.swift",
        newPath: "Sources/App.swift",
        changeType: .modified,
        hunks: [
          DiffHunk(
            id: 0,
            header: "@@ -10,3 +10,3 @@",
            oldStart: 10,
            oldCount: 3,
            newStart: 10,
            newCount: 3,
            lines: [
              DiffLine(type: .removed, content: "old helper()", oldLineNum: 10, newLineNum: nil, prefix: "-"),
              DiffLine(type: .added, content: "new helper()", oldLineNum: nil, newLineNum: 10, prefix: "+"),
              DiffLine(type: .context, content: "return value", oldLineNum: 11, newLineNum: 11, prefix: " "),
            ]
          ),
          DiffHunk(
            id: 1,
            header: "@@ -30,2 +30,2 @@",
            oldStart: 30,
            oldCount: 2,
            newStart: 30,
            newCount: 2,
            lines: [
              DiffLine(type: .context, content: "let count = 1", oldLineNum: 30, newLineNum: 30, prefix: " "),
              DiffLine(type: .added, content: "let count = 2", oldLineNum: nil, newLineNum: 31, prefix: "+"),
            ]
          ),
        ]
      ),
    ])
  }
}
