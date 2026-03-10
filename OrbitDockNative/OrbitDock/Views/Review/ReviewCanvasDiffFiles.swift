import SwiftUI

struct ReviewCanvasDiffFiles<ReviewBanner: View, FileHeader: View>: View {
  let model: DiffModel
  let target: ReviewCursorTarget?
  let reviewComments: [ServerReviewComment]
  let selectedTurnDiffId: String?
  let showResolvedComments: Bool
  @Binding var selectedCommentIds: Set<String>
  @Binding var commentInteraction: ReviewCommentInteractionState
  @Binding var collapsedFiles: Set<String>
  @Binding var collapsedHunks: Set<String>
  @Binding var expandedContextBars: Set<String>
  @ViewBuilder let reviewBanner: () -> ReviewBanner
  @ViewBuilder let fileHeader: (FileDiff, Int, Bool) -> FileHeader
  let onSelectFileHeader: (Int) -> Void
  let onToggleFileCollapse: (Int) -> Void
  let onToggleHunkCollapse: (Int, Int) -> Void
  let mouseSelectionLineIndices: (Int, Int) -> Set<Int>
  let selectionLineIndices: (Int, Int) -> Set<Int>
  let composerLineRangeForHunk: (Int, Int) -> ClosedRange<Int>?
  let onLineComment: (Int, Int, Int, ClosedRange<Int>) -> Void
  let onLineDragChanged: (Int, Int, Int, Int) -> Void
  let onLineDragEnded: (Int, Int, Int, Int) -> Void
  let onSubmitComment: () -> Void
  let onResolveComment: (ServerReviewComment) -> Void

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      reviewBanner()

      ForEach(Array(model.files.enumerated()), id: \.element.id) { fileIdx, file in
        fileSectionHeader(file: file, fileIndex: fileIdx)
          .id("file-\(fileIdx)")
          .onTapGesture {
            onSelectFileHeader(fileIdx)
            onToggleFileCollapse(fileIdx)
          }

        if !collapsedFiles.contains(file.id) {
          fileHunks(file: file, fileIndex: fileIdx)
        }
      }

      Color.clear.frame(height: Spacing.xxl)
    }
  }

  @ViewBuilder
  private func fileHunks(file: FileDiff, fileIndex: Int) -> some View {
    let language = ToolCardStyle.detectLanguage(from: file.newPath)
    let groupedResolved = groupedResolvedComments(forFile: file.newPath)
    let commentedLines = commentedNewLineNums(forFile: file.newPath)

    ForEach(Array(file.hunks.enumerated()), id: \.element.id) { hunkIdx, hunk in
      if hunkIdx > 0 {
        let gap = gapBetweenHunks(previous: file.hunks[hunkIdx - 1], current: hunk)
        if gap > 0 {
          let barKey = "\(fileIndex)-\(hunkIdx)"
          ContextCollapseBar(
            hiddenLineCount: gap,
            isExpanded: Binding(
              get: { expandedContextBars.contains(barKey) },
              set: { isExpanded in
                if isExpanded {
                  expandedContextBars.insert(barKey)
                } else {
                  expandedContextBars.remove(barKey)
                }
              }
            )
          )
        }
      }

      let hunkKey = "\(fileIndex)-\(hunkIdx)"
      let isHunkCollapsed = collapsedHunks.contains(hunkKey)

      DiffHunkView(
        hunk: hunk,
        language: language,
        hunkIndex: hunk.id,
        fileIndex: fileIndex,
        cursorLineIndex: ReviewCursorNavigation.cursorLineForHunk(
          fileIndex: fileIndex,
          hunkIndex: hunkIdx,
          target: target
        ),
        isCursorOnHeader: ReviewCursorNavigation.isCursorOnHunkHeader(
          fileIndex: fileIndex,
          hunkIndex: hunkIdx,
          target: target
        ),
        isHunkCollapsed: isHunkCollapsed,
        commentedLines: commentedLines,
        selectionLines: mouseSelectionLineIndices(fileIndex, hunkIdx)
          .union(selectionLineIndices(fileIndex, hunkIdx)),
        composerLineRange: composerLineRangeForHunk(fileIndex, hunkIdx),
        onLineComment: { clickedIdx, smartRange in
          onLineComment(fileIndex, hunkIdx, clickedIdx, smartRange)
        },
        onLineDragChanged: { anchor, current in
          onLineDragChanged(fileIndex, hunkIdx, anchor, current)
        },
        onLineDragEnded: { startIdx, endIdx in
          onLineDragEnded(fileIndex, hunkIdx, startIdx, endIdx)
        }
      ) { lineIdx, line in
        let inlinePresentation = ReviewCanvasInlinePresentationPlanner.presentation(
          comments: reviewComments,
          filePath: file.newPath,
          newLine: line.newLineNum,
          activeTurnId: selectedTurnDiffId,
          resolvedGroups: groupedResolved,
          composerTarget: commentInteraction.composerTarget,
          fileIndex: fileIndex,
          hunkIndex: hunkIdx,
          lineIndex: lineIdx
        )

        if !inlinePresentation.openComments.isEmpty {
          InlineCommentThread(
            comments: inlinePresentation.openComments,
            selectedIds: selectedCommentIds,
            onResolve: { comment in
              onResolveComment(comment)
            },
            onToggleSelection: { comment in
              if selectedCommentIds.contains(comment.id) {
                selectedCommentIds.remove(comment.id)
              } else {
                selectedCommentIds.insert(comment.id)
              }
            }
          )
          .id("comments-\(fileIndex)-\(hunkIdx)-\(lineIdx)")
        }

        if !inlinePresentation.resolvedComments.isEmpty {
          ResolvedCommentMarker(
            comments: inlinePresentation.resolvedComments,
            onReopen: { comment in
              onResolveComment(comment)
            },
            startExpanded: showResolvedComments
          )
          .id("resolved-\(fileIndex)-\(hunkIdx)-\(lineIdx)")
        }

        if let composerContext = inlinePresentation.composerContext {
          CommentComposerView(
            commentBody: $commentInteraction.composerBody,
            tag: $commentInteraction.composerTag,
            fileName: composerContext.fileName,
            lineLabel: composerContext.lineLabel,
            onSubmit: onSubmitComment,
            onCancel: { commentInteraction.clearComposer() }
          )
          .id("composer-\(fileIndex)-\(hunkIdx)-\(lineIdx)")
        }
      }
    }
  }

  private func fileSectionHeader(file: FileDiff, fileIndex: Int) -> some View {
    fileHeader(file, fileIndex, target == .fileHeader(fileIndex: fileIndex))
  }

  private func groupedResolvedComments(forFile filePath: String) -> [Int: [ServerReviewComment]] {
    ReviewCanvasProjection.groupedResolvedComments(
      comments: reviewComments,
      filePath: filePath,
      activeTurnId: selectedTurnDiffId
    )
  }

  private func commentedNewLineNums(forFile filePath: String) -> Set<Int> {
    ReviewCanvasProjection.commentedNewLineNums(
      comments: reviewComments,
      filePath: filePath,
      activeTurnId: selectedTurnDiffId,
      showResolvedComments: showResolvedComments
    )
  }

  private func gapBetweenHunks(previous: DiffHunk, current: DiffHunk) -> Int {
    let previousEnd = previous.oldStart + previous.oldCount
    let currentStart = current.oldStart
    return max(0, currentStart - previousEnd)
  }
}
