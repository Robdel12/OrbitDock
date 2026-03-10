import Foundation

struct ReviewDragSelection: Equatable {
  let fileIndex: Int
  let hunkIndex: Int
  let lineIndex: Int
}

struct ReviewCommentInteractionState: Equatable {
  var commentMark: ReviewCursorTarget?
  var composerTarget: ReviewComposerLineRange?
  var composerBody = ""
  var composerTag: ServerReviewCommentTag?
  var mouseDragAnchor: ReviewDragSelection?
  var mouseDragCurrent: ReviewDragSelection?

  var hasComposer: Bool {
    composerTarget != nil
  }

  mutating func clearComposer() {
    composerTarget = nil
    composerBody = ""
    composerTag = nil
  }

  mutating func clearMark() {
    commentMark = nil
  }

  mutating func clearMouseDrag() {
    mouseDragAnchor = nil
    mouseDragCurrent = nil
  }

  mutating func beginComposer(target: ReviewComposerLineRange) {
    composerTarget = target
    composerBody = ""
    composerTag = nil
  }

  mutating func beginMouseDrag(fileIndex: Int, hunkIndex: Int, anchorLineIndex: Int, currentLineIndex: Int) {
    commentMark = nil
    mouseDragAnchor = ReviewDragSelection(fileIndex: fileIndex, hunkIndex: hunkIndex, lineIndex: anchorLineIndex)
    mouseDragCurrent = ReviewDragSelection(fileIndex: fileIndex, hunkIndex: hunkIndex, lineIndex: currentLineIndex)
  }

  mutating func cancelActiveInteraction() {
    if commentMark != nil {
      clearMark()
    } else if hasComposer {
      clearComposer()
    }
  }
}
