import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ReviewCommentInteractionStateTests {
  @Test func beginComposerResetsDraftAndTag() {
    var state = ReviewCommentInteractionState(
      commentMark: .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 0),
      composerTarget: nil,
      composerBody: "Old draft",
      composerTag: .risk,
      mouseDragAnchor: nil,
      mouseDragCurrent: nil
    )

    state.beginComposer(target: ReviewComposerLineRange(
      filePath: "Sources/App.swift",
      fileIndex: 0,
      hunkIndex: 0,
      lineStartIdx: 1,
      lineEndIdx: 1,
      lineStart: 10,
      lineEnd: nil
    ))

    #expect(state.composerBody.isEmpty)
    #expect(state.composerTag == nil)
    #expect(state.composerTarget?.lineStart == 10)
    #expect(state.commentMark == .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 0))
  }

  @Test func beginMouseDragClearsKeyboardMarkAndTracksSelection() {
    var state = ReviewCommentInteractionState()
    state.commentMark = .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 2)

    state.beginMouseDrag(fileIndex: 1, hunkIndex: 2, anchorLineIndex: 4, currentLineIndex: 6)

    #expect(state.commentMark == nil)
    #expect(state.mouseDragAnchor == ReviewDragSelection(fileIndex: 1, hunkIndex: 2, lineIndex: 4))
    #expect(state.mouseDragCurrent == ReviewDragSelection(fileIndex: 1, hunkIndex: 2, lineIndex: 6))
  }

  @Test func cancelActiveInteractionClearsMarkBeforeComposer() {
    var state = ReviewCommentInteractionState()
    state.commentMark = .diffLine(fileIndex: 0, hunkIndex: 0, lineIndex: 0)
    state.beginComposer(target: ReviewComposerLineRange(
      filePath: "Sources/App.swift",
      fileIndex: 0,
      hunkIndex: 0,
      lineStartIdx: 0,
      lineEndIdx: 0,
      lineStart: 10,
      lineEnd: nil
    ))

    state.cancelActiveInteraction()
    #expect(state.commentMark == nil)
    #expect(state.composerTarget != nil)

    state.cancelActiveInteraction()
    #expect(state.composerTarget == nil)
    #expect(state.composerBody.isEmpty)
  }
}
