import SwiftUI

extension ReviewCanvas {
  // MARK: - Mouse Interactions

  /// Handle click on the + comment button — uses smart connected block range.
  func handleLineComment(
    fileIdx: Int,
    hunkIdx: Int,
    clickedIdx: Int,
    smartRange: ClosedRange<Int>,
    model: DiffModel
  ) {
    _ = clickedIdx

    guard let composerTarget = ReviewCommentComposerPlanner.smartCommentTarget(
      fileIndex: fileIdx,
      hunkIndex: hunkIdx,
      smartRange: smartRange,
      model: model
    ) else {
      return
    }

    commentInteraction.clearMark()
    commentInteraction.beginComposer(target: composerTarget)
  }

  /// Handle drag update — show selection highlight.
  func handleLineDragChanged(fileIdx: Int, hunkIdx: Int, anchor: Int, current: Int) {
    commentInteraction.beginMouseDrag(
      fileIndex: fileIdx,
      hunkIndex: hunkIdx,
      anchorLineIndex: anchor,
      currentLineIndex: current
    )
  }

  /// Handle drag end — open composer for the dragged range.
  func handleLineDragEnded(fileIdx: Int, hunkIdx: Int, startIdx: Int, endIdx: Int, model: DiffModel) {
    if let composerTarget = ReviewCommentComposerPlanner.dragCommentTarget(
      fileIndex: fileIdx,
      hunkIndex: hunkIdx,
      startLineIndex: startIdx,
      endLineIndex: endIdx,
      model: model
    ) {
      commentInteraction.beginComposer(target: composerTarget)
    }

    commentInteraction.clearMouseDrag()
  }

  /// Line index range within a hunk that has an active composer open.
  func composerLineRangeForHunk(fileIdx: Int, hunkIdx: Int) -> ClosedRange<Int>? {
    ReviewCommentComposerPlanner.composerLineRange(
      composerTarget: commentInteraction.composerTarget,
      fileIndex: fileIdx,
      hunkIndex: hunkIdx
    )
  }

  /// Line indices within a hunk that fall in the mouse drag selection.
  func mouseSelectionLineIndices(fileIdx: Int, hunkIdx: Int) -> Set<Int> {
    ReviewCommentComposerPlanner.mouseSelectionLineIndices(
      anchor: commentInteraction.mouseDragAnchor,
      current: commentInteraction.mouseDragCurrent,
      fileIndex: fileIdx,
      hunkIndex: hunkIdx
    )
  }

  /// Open the comment composer for the current cursor position or mark range.
  func openComposer(model: DiffModel) -> KeyPress.Result {
    let composerTarget = ReviewCommentComposerPlanner.openComposerTarget(
      mark: commentInteraction.commentMark,
      currentTarget: currentTarget(model),
      model: model
    )
    commentInteraction.clearMark()
    guard let composerTarget else { return .handled }
    commentInteraction.beginComposer(target: composerTarget)
    return .handled
  }
}
