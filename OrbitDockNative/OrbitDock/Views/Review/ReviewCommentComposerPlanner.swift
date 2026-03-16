import Foundation

enum ReviewCommentComposerPlanner {
  static func composerLineRange(
    composerTarget: ReviewComposerLineRange?,
    fileIndex: Int,
    hunkIndex: Int
  ) -> ClosedRange<Int>? {
    guard let composerTarget,
          composerTarget.fileIndex == fileIndex,
          composerTarget.hunkIndex == hunkIndex
    else {
      return nil
    }
    return composerTarget.lineStartIdx ... composerTarget.lineEndIdx
  }

  static func selectionLineIndices(
    mark: ReviewCursorTarget?,
    currentTarget: ReviewCursorTarget?,
    model: DiffModel?,
    fileIndex: Int,
    hunkIndex: Int
  ) -> Set<Int> {
    guard let mark,
          let model,
          case let .diffLine(markFileIndex, markHunkIndex, markLineIndex) = mark,
          let currentTarget,
          case let .diffLine(currentFileIndex, currentHunkIndex, currentLineIndex) = currentTarget
    else {
      return []
    }

    guard markFileIndex == currentFileIndex, markFileIndex == fileIndex else { return [] }

    let startHunk = min(markHunkIndex, currentHunkIndex)
    let endHunk = max(markHunkIndex, currentHunkIndex)
    guard hunkIndex >= startHunk, hunkIndex <= endHunk else { return [] }

    let startLine = markHunkIndex < currentHunkIndex ? markLineIndex : (markHunkIndex == currentHunkIndex ? min(
      markLineIndex,
      currentLineIndex
    ) : currentLineIndex)
    let endLine = markHunkIndex < currentHunkIndex ? currentLineIndex : (markHunkIndex == currentHunkIndex ? max(
      markLineIndex,
      currentLineIndex
    ) : markLineIndex)

    if startHunk == endHunk {
      guard hunkIndex == startHunk else { return [] }
      return Set(min(startLine, endLine) ... max(startLine, endLine))
    }

    if hunkIndex == startHunk {
      let hunkLineCount = model.files[fileIndex].hunks[hunkIndex].lines.count
      let lowerBound = markHunkIndex < currentHunkIndex ? markLineIndex : currentLineIndex
      return Set(lowerBound ..< hunkLineCount)
    }

    if hunkIndex == endHunk {
      let upperBound = markHunkIndex < currentHunkIndex ? currentLineIndex : markLineIndex
      return Set(0 ... upperBound)
    }

    let hunkLineCount = model.files[fileIndex].hunks[hunkIndex].lines.count
    return Set(0 ..< hunkLineCount)
  }

  static func mouseSelectionLineIndices(
    anchor: ReviewDragSelection?,
    current: ReviewDragSelection?,
    fileIndex: Int,
    hunkIndex: Int
  ) -> Set<Int> {
    guard let anchor,
          let current,
          anchor.fileIndex == fileIndex,
          anchor.hunkIndex == hunkIndex,
          current.fileIndex == fileIndex,
          current.hunkIndex == hunkIndex
    else {
      return []
    }

    let startLine = min(anchor.lineIndex, current.lineIndex)
    let endLine = max(anchor.lineIndex, current.lineIndex)
    return Set(startLine ... endLine)
  }

  static func canSetMark(for target: ReviewCursorTarget?, model: DiffModel) -> Bool {
    guard let target else { return false }
    return diffLineHasNewLineNum(target, model: model)
  }

  static func smartCommentTarget(
    fileIndex: Int,
    hunkIndex: Int,
    smartRange: ClosedRange<Int>,
    model: DiffModel
  ) -> ReviewComposerLineRange? {
    makeRangeTarget(
      fileIndex: fileIndex,
      hunkIndex: hunkIndex,
      lineStartIndex: smartRange.lowerBound,
      lineEndIndex: smartRange.upperBound,
      model: model
    )
  }

  static func dragCommentTarget(
    fileIndex: Int,
    hunkIndex: Int,
    startLineIndex: Int,
    endLineIndex: Int,
    model: DiffModel
  ) -> ReviewComposerLineRange? {
    makeRangeTarget(
      fileIndex: fileIndex,
      hunkIndex: hunkIndex,
      lineStartIndex: startLineIndex,
      lineEndIndex: endLineIndex,
      model: model
    )
  }

  static func openComposerTarget(
    mark: ReviewCursorTarget?,
    currentTarget: ReviewCursorTarget?,
    model: DiffModel
  ) -> ReviewComposerLineRange? {
    if let mark {
      guard case let .diffLine(markFileIndex, markHunkIndex, markLineIndex) = mark,
            let currentTarget,
            case let .diffLine(currentFileIndex, currentHunkIndex, currentLineIndex) = currentTarget,
            markFileIndex == currentFileIndex
      else {
        return nil
      }

      let startHunk = min(markHunkIndex, currentHunkIndex)
      let endHunk = max(markHunkIndex, currentHunkIndex)
      let startLineIndex = startHunk == endHunk ? min(markLineIndex, currentLineIndex) :
        (markHunkIndex <= currentHunkIndex
          ? markLineIndex : currentLineIndex)
      let endLineIndex = startHunk == endHunk ? max(markLineIndex, currentLineIndex) :
        (markHunkIndex <= currentHunkIndex
          ? currentLineIndex : markLineIndex)

      guard let range = makeRangeTarget(
        fileIndex: markFileIndex,
        hunkIndex: endHunk,
        lineStartIndex: startLineIndex,
        lineEndIndex: endLineIndex,
        lineStartHunkIndex: startHunk,
        model: model
      ) else {
        return nil
      }

      return range
    }

    guard let currentTarget,
          case let .diffLine(fileIndex, hunkIndex, lineIndex) = currentTarget
    else {
      return nil
    }

    return makeRangeTarget(
      fileIndex: fileIndex,
      hunkIndex: hunkIndex,
      lineStartIndex: lineIndex,
      lineEndIndex: lineIndex,
      model: model
    )
  }

  private static func makeRangeTarget(
    fileIndex: Int,
    hunkIndex: Int,
    lineStartIndex: Int,
    lineEndIndex: Int,
    lineStartHunkIndex: Int? = nil,
    model: DiffModel
  ) -> ReviewComposerLineRange? {
    guard fileIndex < model.files.count else { return nil }

    let file = model.files[fileIndex]
    guard hunkIndex < file.hunks.count else { return nil }
    let hunk = file.hunks[hunkIndex]

    let sortedStartIndex = min(lineStartIndex, lineEndIndex)
    let sortedEndIndex = max(lineStartIndex, lineEndIndex)

    let startHunkIndex = lineStartHunkIndex ?? hunkIndex
    guard startHunkIndex < file.hunks.count else { return nil }
    let startHunk = file.hunks[startHunkIndex]

    let startNewLine = firstNewLineNumber(in: startHunk, from: sortedStartIndex, through: sortedEndIndex)
    let endNewLine = lastNewLineNumber(in: hunk, from: sortedStartIndex, through: sortedEndIndex)
    guard let startNewLine else { return nil }

    return ReviewComposerLineRange(
      filePath: file.newPath,
      fileIndex: fileIndex,
      hunkIndex: hunkIndex,
      lineStartIdx: sortedStartIndex,
      lineEndIdx: sortedEndIndex,
      lineStart: UInt32(startNewLine),
      lineEnd: endNewLine.map(UInt32.init)
    )
  }

  private static func firstNewLineNumber(in hunk: DiffHunk, from start: Int, through end: Int) -> Int? {
    guard !hunk.lines.isEmpty else { return nil }
    let lowerBound = max(0, min(start, hunk.lines.count - 1))
    let upperBound = max(0, min(end, hunk.lines.count - 1))
    guard lowerBound <= upperBound else { return nil }

    for index in lowerBound ... upperBound {
      if let lineNumber = hunk.lines[index].newLineNum {
        return lineNumber
      }
    }
    return nil
  }

  private static func lastNewLineNumber(in hunk: DiffHunk, from start: Int, through end: Int) -> Int? {
    guard !hunk.lines.isEmpty else { return nil }
    let lowerBound = max(0, min(start, hunk.lines.count - 1))
    let upperBound = max(0, min(end, hunk.lines.count - 1))
    guard lowerBound <= upperBound else { return nil }

    for index in stride(from: upperBound, through: lowerBound, by: -1) {
      if let lineNumber = hunk.lines[index].newLineNum {
        return lineNumber
      }
    }
    return nil
  }

  private static func diffLineHasNewLineNum(_ target: ReviewCursorTarget, model: DiffModel) -> Bool {
    guard case let .diffLine(fileIndex, hunkIndex, lineIndex) = target,
          fileIndex < model.files.count
    else {
      return false
    }

    let file = model.files[fileIndex]
    guard hunkIndex < file.hunks.count else { return false }
    let hunk = file.hunks[hunkIndex]
    guard lineIndex < hunk.lines.count else { return false }
    return hunk.lines[lineIndex].newLineNum != nil
  }
}
