import Foundation
@testable import OrbitDock
import Testing

struct ReviewCanvasRoutingTests {
  @Test func fileIndexMatchesExactIdentifiersAndPathSuffixes() {
    let model = makeReviewDiffModel()

    #expect(ReviewCanvasRoutingPlanner.fileIndex(for: "Sources/App.swift", in: model) == 0)
    #expect(ReviewCanvasRoutingPlanner.fileIndex(for: "App.swift", in: model) == 0)
    #expect(ReviewCanvasRoutingPlanner.fileIndex(for: "Sources/Other.swift", in: model) == 1)
    #expect(ReviewCanvasRoutingPlanner.fileIndex(for: "Missing.swift", in: model) == nil)
  }

  @Test func selectedFileIdUsesCurrentCursorTargetFileIndex() {
    let model = makeReviewDiffModel()

    #expect(
      ReviewCanvasRoutingPlanner.selectedFileId(
        for: .diffLine(fileIndex: 1, hunkIndex: 0, lineIndex: 0),
        in: model
      ) == "Sources/Other.swift"
    )
    #expect(ReviewCanvasRoutingPlanner.selectedFileId(for: nil, in: model) == nil)
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
          )
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
          )
        ]
      ),
    ])
  }
}
