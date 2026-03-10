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

    let turnId = selectedTurnDiffId ?? inferTurnId(forFile: ct.filePath)

    Task {
      _ = try? await serverState.clients.approvals.createReviewComment(
        sessionId: sessionId,
        request: ApprovalsClient.CreateReviewCommentRequest(
          turnId: turnId,
          filePath: ct.filePath,
          lineStart: ct.lineStart,
          lineEnd: ct.lineEnd,
          body: trimmed,
          tag: commentInteraction.composerTag
        )
      )
    }

    commentInteraction.clearComposer()
  }

  func resolveComment(_ comment: ServerReviewComment) {
    let newStatus: ServerReviewCommentStatus = comment.status == .open ? .resolved : .open
    Task {
      try? await serverState.clients.approvals.updateReviewComment(
        commentId: comment.id,
        body: ApprovalsClient.UpdateReviewCommentRequest(status: newStatus)
      )
    }
  }

  func resolveCommentAtCursor(model: DiffModel) {
    guard let target = currentTarget(model),
          case let .diffLine(f, _, _) = target else { return }

    let file = model.files[f]
    guard case let .diffLine(_, h, l) = target else { return }
    let line = file.hunks[h].lines[l]
    guard let newLine = line.newLineNum else { return }

    let lineComments = commentsForLine(filePath: file.newPath, lineNum: newLine)
    if let first = lineComments.first(where: { $0.status == .open }) {
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

    let lineComments = commentsForLine(filePath: file.newPath, lineNum: newLine)
    for comment in lineComments where comment.status == .open {
      if selectedCommentIds.contains(comment.id) {
        selectedCommentIds.remove(comment.id)
      } else {
        selectedCommentIds.insert(comment.id)
      }
    }
  }

  /// Infer which turn a comment belongs to by finding the latest turn that touched the file.
  /// Used when commenting on "All Changes" — maps the comment to the right edit turn.
  func inferTurnId(forFile filePath: String) -> String? {
    for turnDiff in obs.turnDiffs.reversed() {
      if ReviewWorkflow.diffMentionsFile(turnDiff.diff, filePath: filePath) {
        return turnDiff.turnId
      }
    }
    return nil
  }
}
