@testable import OrbitDock
import Testing

struct ReviewCanvasToolbarStateTests {
  @Test func toolbarStateBuildsCurrentFileHistoryFollowAndTotals() {
    let state = ReviewCanvasToolbarPlanner.toolbarState(
      currentFilePath: "Sources/Feature/ReviewCanvas.swift",
      model: makeModel(),
      hasResolvedComments: true,
      showResolvedComments: true,
      isSessionActive: true,
      isFollowing: false
    )

    #expect(state.currentFileName == "ReviewCanvas.swift")
    #expect(state.totalAdditions == 5)
    #expect(state.totalDeletions == 2)
    #expect(state.history?.isVisible == true)
    #expect(state.history?.iconName == "eye.fill")
    #expect(state.follow?.isFollowing == false)
    #expect(state.follow?.label == "Paused")
  }

  @Test func toolbarStateOmitsHistoryAndFollowWhenUnavailable() {
    let state = ReviewCanvasToolbarPlanner.toolbarState(
      currentFilePath: nil,
      model: makeModel(),
      hasResolvedComments: false,
      showResolvedComments: false,
      isSessionActive: false,
      isFollowing: true
    )

    #expect(state.currentFileName == nil)
    #expect(state.history == nil)
    #expect(state.follow == nil)
  }

  private func makeModel() -> DiffModel {
    DiffModel(files: [
      FileDiff(
        id: "Sources/App.swift",
        oldPath: "Sources/App.swift",
        newPath: "Sources/App.swift",
        changeType: .modified,
        hunks: [
          DiffHunk(
            id: 0,
            header: "@@ -1,1 +1,2 @@",
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 2,
            lines: [
              DiffLine(type: .removed, content: "old", oldLineNum: 1, newLineNum: nil, prefix: "-"),
              DiffLine(type: .added, content: "new", oldLineNum: nil, newLineNum: 1, prefix: "+"),
              DiffLine(type: .added, content: "newer", oldLineNum: nil, newLineNum: 2, prefix: "+"),
            ]
          ),
        ]
      ),
      FileDiff(
        id: "Sources/Feature.swift",
        oldPath: "Sources/Feature.swift",
        newPath: "Sources/Feature.swift",
        changeType: .modified,
        hunks: [
          DiffHunk(
            id: 1,
            header: "@@ -10,1 +10,4 @@",
            oldStart: 10,
            oldCount: 1,
            newStart: 10,
            newCount: 4,
            lines: [
              DiffLine(type: .removed, content: "stale", oldLineNum: 10, newLineNum: nil, prefix: "-"),
              DiffLine(type: .added, content: "fresh", oldLineNum: nil, newLineNum: 10, prefix: "+"),
              DiffLine(type: .added, content: "fresher", oldLineNum: nil, newLineNum: 11, prefix: "+"),
              DiffLine(type: .added, content: "freshest", oldLineNum: nil, newLineNum: 12, prefix: "+"),
            ]
          ),
        ]
      ),
    ])
  }
}
