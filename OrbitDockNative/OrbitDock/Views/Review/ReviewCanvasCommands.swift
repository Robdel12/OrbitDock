//
//  ReviewCanvasCommands.swift
//  OrbitDock
//
//  Keyboard command handling and cursor navigation for the review canvas.
//

import SwiftUI

extension ReviewCanvas {
  // MARK: - Keyboard Handling (magit-style)

  //
  // C-n / C-p    — move cursor one line (Emacs line nav)
  // C-f / C-b    — jump cursor to next/prev section (file + hunk headers)
  // C-space      — set mark for range selection
  // n / p        — jump cursor to next/prev section (file + hunk headers)
  // c            — open comment composer (range if mark, single line otherwise)
  // ] / [        — jump to next/prev unresolved comment
  // r            — toggle resolve on comment at cursor
  // TAB          — toggle collapse at cursor (file header → file, hunk → hunk)
  // RET          — open file in editor (dedicated handler)
  // q            — close review pane
  // f            — toggle follow mode

  func handleKeyPress(_ keyPress: KeyPress, model: DiffModel) -> KeyPress.Result {
    // Emacs: C-n (next line)
    if keyPress.key == "n", keyPress.modifiers.contains(.control) {
      moveCursor(by: 1, in: model)
      return .handled
    }
    // Emacs: C-p (previous line)
    if keyPress.key == "p", keyPress.modifiers.contains(.control) {
      moveCursor(by: -1, in: model)
      return .handled
    }
    // Emacs: C-f (forward — next hunk)
    if keyPress.key == "f", keyPress.modifiers.contains(.control) {
      jumpToNextHunk(forward: true, in: model)
      return .handled
    }
    // Emacs: C-b (backward — prev hunk)
    if keyPress.key == "b", keyPress.modifiers.contains(.control) {
      jumpToNextHunk(forward: false, in: model)
      return .handled
    }
    // Emacs: C-g — abort / cancel mark / cancel composer
    if keyPress.key == "g", keyPress.modifiers.contains(.control) {
      commentInteraction.cancelActiveInteraction()
      return .handled
    }
    // C-space — set mark for range selection
    if keyPress.key == " ", keyPress.modifiers.contains(.control) {
      let target = currentTarget(model)
      if ReviewCommentComposerPlanner.canSetMark(for: target, model: model) {
        commentInteraction.commentMark = target
      }
      return .handled
    }

    // Shift+S — send review comments to model (selected if any, else all open)
    if keyPress.key == "S", keyPress.modifiers == .shift {
      sendReview()
      return .handled
    }

    // Shift+X — clear all comment selections
    if keyPress.key == "X", keyPress.modifiers == .shift {
      selectedCommentIds.removeAll()
      return .handled
    }

    // Bare keys (no modifiers)
    guard keyPress.modifiers.isEmpty else { return .ignored }

    switch keyPress.key {
      case "n":
        jumpToNextHunk(forward: true, in: model)
        return .handled

      case "p":
        jumpToNextHunk(forward: false, in: model)
        return .handled

      case "c":
        return openComposer(model: model)

      case "]":
        jumpToNextComment(forward: true, in: model)
        return .handled

      case "[":
        jumpToNextComment(forward: false, in: model)
        return .handled

      case "r":
        resolveCommentAtCursor(model: model)
        return .handled

      case "x":
        toggleSelectionAtCursor(model: model)
        return .handled

      case "q":
        onDismiss?()
        return onDismiss != nil ? .handled : .ignored

      case "f":
        isFollowing.toggle()
        if isFollowing {
          let targets = visibleTargets(model)
          if let lastFile = targets.lastIndex(where: { $0.isFileHeader }) {
            cursorIndex = lastFile
          }
        }
        return .handled

      default:
        return .ignored
    }
  }

  // MARK: - Cursor Movement

  func moveCursor(by delta: Int, in model: DiffModel) {
    let targets = visibleTargets(model)
    guard let nextIndex = ReviewCursorNavigation.movedCursor(
      currentIndex: cursorIndex,
      delta: delta,
      targets: targets
    ) else { return }
    isFollowing = false
    cursorIndex = nextIndex
  }

  func jumpToNextHunk(forward: Bool, in model: DiffModel) {
    let targets = visibleTargets(model)
    guard let nextIndex = ReviewCursorNavigation.jumpedToNextSection(
      currentIndex: cursorIndex,
      forward: forward,
      targets: targets
    ) else { return }
    isFollowing = false
    cursorIndex = nextIndex
  }

  // MARK: - Collapse

  func toggleCollapseAtCursor(model: DiffModel, fileIdx: Int) {
    guard fileIdx < model.files.count else { return }
    let fileId = model.files[fileIdx].id

    withAnimation(Motion.snappy) {
      collapsedFiles = ReviewCursorNavigation.toggledFileCollapse(
        fileId: fileId,
        collapsedFiles: collapsedFiles
      )
    }

    let newTargets = visibleTargets(model)
    if let idx = ReviewCursorNavigation.fileHeaderIndex(fileIndex: fileIdx, targets: newTargets) {
      cursorIndex = idx
    } else if !newTargets.isEmpty {
      cursorIndex = min(cursorIndex, newTargets.count - 1)
    }
  }

  func toggleHunkCollapse(model: DiffModel, fileIdx: Int, hunkIdx: Int) {
    let hunkKey = ReviewCursorNavigation.hunkCollapseKey(fileIndex: fileIdx, hunkIndex: hunkIdx)

    withAnimation(Motion.snappy) {
      collapsedHunks = ReviewCursorNavigation.toggledHunkCollapse(
        hunkKey: hunkKey,
        collapsedHunks: collapsedHunks
      )
    }

    let newTargets = visibleTargets(model)
    if let idx = ReviewCursorNavigation.hunkHeaderIndex(
      fileIndex: fileIdx,
      hunkIndex: hunkIdx,
      targets: newTargets
    ) {
      cursorIndex = idx
    } else if !newTargets.isEmpty {
      cursorIndex = min(cursorIndex, newTargets.count - 1)
    }
  }

  // MARK: - Comment Navigation

  func jumpToNextComment(forward: Bool, in model: DiffModel) {
    let targets = visibleTargets(model)
    guard !targets.isEmpty else { return }
    let safeIdx = min(cursorIndex, targets.count - 1)

    let unresolvedFiles = buildUnresolvedCommentLineMap(model: model)

    let forwardRange = Array((safeIdx + 1) ..< targets.count) + Array(0 ..< safeIdx)
    let backwardHead = Array(stride(from: safeIdx - 1, through: 0, by: -1))
    let backwardTail = Array(stride(from: targets.count - 1, through: safeIdx + 1, by: -1))
    let backwardRange = backwardHead + backwardTail
    let range = forward ? forwardRange : backwardRange

    for i in range {
      guard case let .diffLine(f, h, l) = targets[i] else { continue }
      let file = model.files[f]
      let line = file.hunks[h].lines[l]
      guard let newLine = line.newLineNum else { continue }

      if let fileSet = unresolvedFiles[file.newPath], fileSet.contains(newLine) {
        if collapsedFiles.contains(file.id) {
          _ = withAnimation(Motion.snappy) {
            collapsedFiles.remove(file.id)
          }
        }
        let hunkKey = "\(f)-\(h)"
        if collapsedHunks.contains(hunkKey) {
          _ = withAnimation(Motion.snappy) {
            collapsedHunks.remove(hunkKey)
          }
        }

        let newTargets = visibleTargets(model)
        if let newIdx = newTargets.firstIndex(
          of: ReviewCursorTarget.diffLine(fileIndex: f, hunkIndex: h, lineIndex: l)
        ) {
          isFollowing = false
          cursorIndex = newIdx
        } else {
          isFollowing = false
          cursorIndex = i
        }
        return
      }
    }
  }

  func buildUnresolvedCommentLineMap(model _: DiffModel) -> [String: Set<Int>] {
    ReviewCanvasProjection.unresolvedCommentLineMap(
      comments: obs.reviewComments,
      activeTurnId: selectedTurnDiffId
    )
  }

  // MARK: - Navigate to Comment

  func handleNavigateToComment(_ model: DiffModel) {
    guard let comment = navigateToComment?.wrappedValue else { return }

    guard let fileIdx = model.files.firstIndex(where: { $0.newPath == comment.filePath }) else {
      navigateToComment?.wrappedValue = nil
      return
    }
    let file = model.files[fileIdx]

    if collapsedFiles.contains(file.id) {
      _ = withAnimation(Motion.snappy) {
        collapsedFiles.remove(file.id)
      }
    }

    for (hunkIdx, hunk) in file.hunks.enumerated() {
      for (lineIdx, line) in hunk.lines.enumerated() {
        if let newLine = line.newLineNum, newLine == Int(comment.lineStart) {
          let hunkKey = "\(fileIdx)-\(hunkIdx)"
          if collapsedHunks.contains(hunkKey) {
            _ = withAnimation(Motion.snappy) {
              collapsedHunks.remove(hunkKey)
            }
          }

          let targets = visibleTargets(model)
          if let idx = targets.firstIndex(
            of: ReviewCursorTarget.diffLine(fileIndex: fileIdx, hunkIndex: hunkIdx, lineIndex: lineIdx)
          ) {
            isFollowing = false
            cursorIndex = idx
          }

          navigateToComment?.wrappedValue = nil
          return
        }
      }
    }

    navigateToComment?.wrappedValue = nil
  }
}
