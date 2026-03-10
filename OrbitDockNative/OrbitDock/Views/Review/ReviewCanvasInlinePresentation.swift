import Foundation

enum ReviewCanvasInlinePresentationPlanner {
  static func presentation(
    comments: [ServerReviewComment],
    filePath: String,
    newLine: Int?,
    activeTurnId: String?,
    resolvedGroups: [Int: [ServerReviewComment]],
    composerTarget: ReviewComposerLineRange?,
    fileIndex: Int,
    hunkIndex: Int,
    lineIndex: Int
  ) -> ReviewCanvasInlinePresentation {
    let openComments: [ServerReviewComment]
    let resolvedComments: [ServerReviewComment]

    if let newLine {
      openComments = ReviewCanvasProjection.commentsForLine(
        comments: comments,
        filePath: filePath,
        lineNum: newLine,
        activeTurnId: activeTurnId
      ).filter { $0.status == .open }
      resolvedComments = resolvedGroups[newLine] ?? []
    } else {
      openComments = []
      resolvedComments = []
    }

    return ReviewCanvasInlinePresentation(
      openComments: openComments,
      resolvedComments: resolvedComments,
      composerContext: composerContext(
        composerTarget: composerTarget,
        fileIndex: fileIndex,
        hunkIndex: hunkIndex,
        lineIndex: lineIndex
      )
    )
  }

  static func composerContext(
    composerTarget: ReviewComposerLineRange?,
    fileIndex: Int,
    hunkIndex: Int,
    lineIndex: Int
  ) -> ReviewCanvasInlineComposerContext? {
    guard let composerTarget,
          composerTarget.fileIndex == fileIndex,
          composerTarget.hunkIndex == hunkIndex,
          composerTarget.lineEndIdx == lineIndex
    else {
      return nil
    }

    let fileName = composerTarget.filePath.components(separatedBy: "/").last ?? composerTarget.filePath
    let lineLabel: String
    if let lineEnd = composerTarget.lineEnd, lineEnd != composerTarget.lineStart {
      lineLabel = "Lines \(composerTarget.lineStart)–\(lineEnd)"
    } else {
      lineLabel = "Line \(composerTarget.lineStart)"
    }

    return ReviewCanvasInlineComposerContext(
      fileName: fileName,
      lineLabel: lineLabel
    )
  }
}
