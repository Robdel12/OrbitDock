import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ReviewCanvasCursorNavigationTests {
  @Test func visibleTargetsRespectCollapsedFilesAndHunks() {
    let model = makeReviewDiffModel()

    let allTargets = ReviewCursorNavigation.visibleTargets(
      in: model,
      collapsedFiles: [],
      collapsedHunks: []
    )
    #expect(allTargets == [
      .fileHeader(fileIndex: 0),
      .hunkHeader(fileIndex: 0, hunkIndex: 0),
      .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 0),
      .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 1),
      .hunkHeader(fileIndex: 0, hunkIndex: 1),
      .diffLine(fileIndex: 0, hunkIndex: 1, lineIndex: 0),
      .fileHeader(fileIndex: 1),
      .hunkHeader(fileIndex: 1, hunkIndex: 0),
      .diffLine(fileIndex: 1, hunkIndex: 0, lineIndex: 0),
    ])

    let collapsedFileTargets = ReviewCursorNavigation.visibleTargets(
      in: model,
      collapsedFiles: ["Sources/App.swift"],
      collapsedHunks: []
    )
    #expect(collapsedFileTargets == [
      .fileHeader(fileIndex: 0),
      .fileHeader(fileIndex: 1),
      .hunkHeader(fileIndex: 1, hunkIndex: 0),
      .diffLine(fileIndex: 1, hunkIndex: 0, lineIndex: 0),
    ])

    let collapsedHunkTargets = ReviewCursorNavigation.visibleTargets(
      in: model,
      collapsedFiles: [],
      collapsedHunks: [ReviewCursorNavigation.hunkCollapseKey(fileIndex: 0, hunkIndex: 1)]
    )
    #expect(collapsedHunkTargets == [
      .fileHeader(fileIndex: 0),
      .hunkHeader(fileIndex: 0, hunkIndex: 0),
      .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 0),
      .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 1),
      .hunkHeader(fileIndex: 0, hunkIndex: 1),
      .fileHeader(fileIndex: 1),
      .hunkHeader(fileIndex: 1, hunkIndex: 0),
      .diffLine(fileIndex: 1, hunkIndex: 0, lineIndex: 0),
    ])
  }

  @Test func movedCursorClampsToVisibleBounds() {
    let targets: [ReviewCursorTarget] = [
      .fileHeader(fileIndex: 0),
      .hunkHeader(fileIndex: 0, hunkIndex: 0),
      .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 0),
    ]

    #expect(ReviewCursorNavigation.movedCursor(currentIndex: 1, delta: 1, targets: targets) == 2)
    #expect(ReviewCursorNavigation.movedCursor(currentIndex: 1, delta: -5, targets: targets) == 0)
    #expect(ReviewCursorNavigation.movedCursor(currentIndex: 1, delta: 10, targets: targets) == 2)
    #expect(ReviewCursorNavigation.movedCursor(currentIndex: 0, delta: 1, targets: []) == nil)
  }

  @Test func jumpedToNextSectionMovesAcrossHeadersDeterministically() {
    let targets: [ReviewCursorTarget] = [
      .fileHeader(fileIndex: 0),
      .hunkHeader(fileIndex: 0, hunkIndex: 0),
      .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 0),
      .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 1),
      .hunkHeader(fileIndex: 0, hunkIndex: 1),
      .diffLine(fileIndex: 0, hunkIndex: 1, lineIndex: 0),
      .fileHeader(fileIndex: 1),
    ]

    #expect(ReviewCursorNavigation.jumpedToNextSection(currentIndex: 0, forward: true, targets: targets) == 1)
    #expect(ReviewCursorNavigation.jumpedToNextSection(currentIndex: 2, forward: true, targets: targets) == 4)
    #expect(ReviewCursorNavigation.jumpedToNextSection(currentIndex: 5, forward: true, targets: targets) == 6)
    #expect(ReviewCursorNavigation.jumpedToNextSection(currentIndex: 3, forward: false, targets: targets) == 1)
    #expect(ReviewCursorNavigation.jumpedToNextSection(currentIndex: 4, forward: false, targets: targets) == 1)
    #expect(ReviewCursorNavigation.jumpedToNextSection(currentIndex: 0, forward: false, targets: targets) == nil)
  }

  @Test func currentTargetAndFileHelpersUseProjectedTargets() {
    let model = makeReviewDiffModel()
    let targets = ReviewCursorNavigation.visibleTargets(in: model, collapsedFiles: [], collapsedHunks: [])

    let target = ReviewCursorNavigation.currentTarget(cursorIndex: 3, targets: targets)
    #expect(target == .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 1))
    #expect(ReviewCursorNavigation.currentFileIndex(target: target) == 0)
    #expect(ReviewCursorNavigation.currentFile(in: model, target: target)?.newPath == "Sources/App.swift")
    #expect(ReviewCursorNavigation.cursorLineForHunk(fileIndex: 0, hunkIndex: 0, target: target) == 1)
    #expect(ReviewCursorNavigation.isCursorOnHunkHeader(fileIndex: 0, hunkIndex: 0, target: target) == false)
  }

  @Test func autoFollowReturnsLastFileHeaderWhenNewFilesAppear() {
    let model = makeReviewDiffModel()
    let targets = ReviewCursorNavigation.visibleTargets(in: model, collapsedFiles: [], collapsedHunks: [])

    let followIndex = ReviewCursorNavigation.autoFollowFileHeaderIndex(
      isFollowing: true,
      isSessionActive: true,
      previousFileCount: 1,
      newFileCount: 2,
      targets: targets
    )

    #expect(followIndex == 6)
    #expect(ReviewCursorNavigation.autoFollowFileHeaderIndex(
      isFollowing: false,
      isSessionActive: true,
      previousFileCount: 1,
      newFileCount: 2,
      targets: targets
    ) == nil)
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
            header: "@@ -1,2 +1,2 @@",
            oldStart: 1,
            oldCount: 2,
            newStart: 1,
            newCount: 2,
            lines: [
              DiffLine(type: .context, content: "let title = \"Old\"", oldLineNum: 1, newLineNum: 1, prefix: " "),
              DiffLine(type: .added, content: "let title = \"New\"", oldLineNum: nil, newLineNum: 2, prefix: "+"),
            ]
          ),
          DiffHunk(
            id: 1,
            header: "@@ -10,1 +10,1 @@",
            oldStart: 10,
            oldCount: 1,
            newStart: 10,
            newCount: 1,
            lines: [
              DiffLine(type: .removed, content: "return old", oldLineNum: 10, newLineNum: nil, prefix: "-"),
            ]
          ),
        ]
      ),
      FileDiff(
        id: "Sources/Other.swift",
        oldPath: "Sources/Other.swift",
        newPath: "Sources/Other.swift",
        changeType: .modified,
        hunks: [
          DiffHunk(
            id: 0,
            header: "@@ -1,1 +1,1 @@",
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 1,
            lines: [
              DiffLine(type: .added, content: "print(\"hi\")", oldLineNum: nil, newLineNum: 1, prefix: "+"),
            ]
          ),
        ]
      ),
    ])
  }
}
