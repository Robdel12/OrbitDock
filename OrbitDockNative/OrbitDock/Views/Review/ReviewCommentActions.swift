//
//  ReviewCommentActions.swift
//  OrbitDock
//
//  Effectful review comment mutations and selection toggles.
//

import Foundation

extension ReviewCanvas {
  // MARK: - Comment Mutations

  /// Submit the current comment to the server.
  /// Associates the comment with the correct turn diff — either the one being viewed,
  /// or auto-inferred from the file when on "All Changes" view.
  func submitComment() {
    guard let ct = commentInteraction.composerTarget else { return }
    let trimmed = commentInteraction.composerBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let turnId = selectedTurnDiffId ?? viewModel.inferTurnId(forFile: ct.filePath)
    viewModel.createReviewComment(
      turnId: turnId,
      filePath: ct.filePath,
      lineStart: ct.lineStart,
      lineEnd: ct.lineEnd,
      body: trimmed,
      tag: commentInteraction.composerTag
    )

    commentInteraction.clearComposer()
  }

  func resolveComment(_ comment: ServerReviewComment) {
    let newStatus: ServerReviewCommentStatus = comment.status == .open ? .resolved : .open
    viewModel.updateCommentStatus(commentId: comment.id, status: newStatus)
  }

  func resolveCommentAtCursor(model: DiffModel) {
    guard let target = currentTarget(model),
          case let .diffLine(f, _, _) = target else { return }

    let file = model.files[f]
    guard case let .diffLine(_, h, l) = target else { return }
    let line = file.hunks[h].lines[l]
    guard let newLine = line.newLineNum else { return }

    let lineComments = ReviewCanvasProjection.commentsForLine(
      comments: viewModel.reviewComments,
      filePath: file.newPath,
      lineNum: newLine,
      activeTurnId: selectedTurnDiffId
    )
    if let first = lineComments.first(where: { $0.status == ServerReviewCommentStatus.open }) {
      resolveComment(first)
    } else if let first = lineComments.first {
      resolveComment(first)
    }
  }

  func toggleSelectionAtCursor(model: DiffModel) {
    guard let target = currentTarget(model),
          case let .diffLine(f, _, _) = target else { return }

    let file = model.files[f]
    guard case let .diffLine(_, h, l) = target else { return }
    let line = file.hunks[h].lines[l]
    guard let newLine = line.newLineNum else { return }

    let lineComments = ReviewCanvasProjection.commentsForLine(
      comments: viewModel.reviewComments,
      filePath: file.newPath,
      lineNum: newLine,
      activeTurnId: selectedTurnDiffId
    )
    for comment in lineComments where comment.status == ServerReviewCommentStatus.open {
      if selectedCommentIds.contains(comment.id) {
        selectedCommentIds.remove(comment.id)
      } else {
        selectedCommentIds.insert(comment.id)
      }
    }
  }
}
