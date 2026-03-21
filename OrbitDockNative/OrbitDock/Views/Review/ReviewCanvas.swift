//
//  ReviewCanvas.swift
//  OrbitDock
//
//  Magit-style unified review canvas with non-editable cursor navigation.
//  All files and diffs in one scrollable view with collapsible file sections.
//
//  Cursor model:
//    C-n / C-p    — move cursor one line up/down
//    C-f / C-b    — jump to next/prev section (file + hunk headers)
//    n / p        — jump to next/prev section (file + hunk headers)
//    TAB          — toggle collapse at cursor (file header → file, hunk → hunk)
//    RET          — open file at cursor in editor
//    q            — close review pane
//    f            — toggle follow mode
//
//  Comment model:
//    C-space      — set mark for range selection
//    c            — open comment composer (range if mark active, single line otherwise)
//    C-g / Escape — clear mark / cancel composer (Emacs abort)
//    ] / [        — jump to next/prev unresolved comment
//    r            — toggle resolve on comment at cursor
//    x            — toggle selection on comment at cursor (for partial sends)
//    X            — clear all selections (Shift+X)
//    S            — send comments to model (selected only if any, else all open)
//

import SwiftUI

// MARK: - ReviewCanvas

struct ReviewCanvas: View {
  let sessionId: String
  let sessionStore: SessionStore
  let projectPath: String
  let isSessionActive: Bool
  var compact: Bool = false
  var navigateToFileId: Binding<String?>?
  var onDismiss: (() -> Void)?
  @Binding var selectedCommentIds: Set<String>
  var navigateToComment: Binding<ServerReviewComment?>?

  @State var cursorIndex: Int = 0
  @State var collapsedFiles: Set<String> = []
  @State var collapsedHunks: Set<String> = []
  @State var expandedContextBars: Set<String> = []
  @State var selectedTurnDiffId: String?
  @State var isFollowing = true
  @State private var previousFileCount = 0
  @FocusState var isCanvasFocused: Bool

  /// Comment interaction state
  @State var commentInteraction = ReviewCommentInteractionState()

  // Review round tracking — detects which files the model modified after feedback
  @State var reviewRoundTracker = ReviewRoundTrackerState()
  @State var showResolvedComments: Bool = false

  /// Diff parsing cache — avoids re-parsing on every body evaluation
  @State private var diffParseCache = ReviewDiffParseCache()
  @State var viewModel = ReviewCanvasViewModel()

  private var rawDiff: String? {
    viewModel.rawDiff(selectedTurnDiffId: selectedTurnDiffId)
  }

  var diffModel: DiffModel? {
    diffParseCache.model(for: rawDiff)
  }

  var commentCounts: [String: Int] {
    ReviewCanvasProjection.commentCounts(
      comments: viewModel.reviewComments,
      activeTurnId: selectedTurnDiffId
    )
  }

  var reviewSendBarState: ReviewSendBarState? {
    ReviewCanvasProjection.sendBarState(
      comments: viewModel.reviewComments,
      selectedCommentIds: selectedCommentIds,
      activeTurnId: selectedTurnDiffId
    )
  }

  var hasResolvedComments: Bool {
    ReviewCanvasProjection.hasResolvedComments(
      comments: viewModel.reviewComments,
      activeTurnId: selectedTurnDiffId
    )
  }

  var reviewBannerState: ReviewBannerState? {
    ReviewRoundTracker.bannerState(
      state: reviewRoundTracker,
      turnDiffs: viewModel.turnDiffs
    )
  }

  // MARK: - Cursor Helpers

  func visibleTargets(_ model: DiffModel) -> [ReviewCursorTarget] {
    ReviewCursorNavigation.visibleTargets(
      in: model,
      collapsedFiles: collapsedFiles,
      collapsedHunks: collapsedHunks
    )
  }

  func currentTarget(_ model: DiffModel) -> ReviewCursorTarget? {
    ReviewCursorNavigation.currentTarget(cursorIndex: cursorIndex, targets: visibleTargets(model))
  }

  func currentFileIndex(_ model: DiffModel) -> Int {
    ReviewCursorNavigation.currentFileIndex(target: currentTarget(model))
  }

  func currentFile(_ model: DiffModel) -> FileDiff? {
    ReviewCursorNavigation.currentFile(in: model, target: currentTarget(model))
  }

  // MARK: - Body

  var body: some View {
    Group {
      if let model = diffModel, !model.files.isEmpty {
        if compact {
          compactLayout(model)
        } else {
          fullLayout(model)
        }
      } else {
        ReviewEmptyState(isSessionActive: isSessionActive)
      }
    }
    .background(Color.backgroundPrimary)
    .task(id: "\(sessionStore.endpointId.uuidString):\(sessionId)") {
      viewModel.bind(sessionId: sessionId, sessionStore: sessionStore)
    }
    .onChange(of: rawDiff) { _, _ in
      guard let model = diffModel else { return }
      let targets = visibleTargets(model)
      let refreshState = ReviewCanvasStatePlanner.refreshState(
        cursorIndex: cursorIndex,
        previousFileCount: previousFileCount,
        isFollowing: isFollowing,
        isSessionActive: isSessionActive,
        newFileCount: model.files.count,
        targets: targets
      )
      cursorIndex = refreshState.cursorIndex
      previousFileCount = refreshState.previousFileCount
    }
    .onChange(of: navigateToFileId?.wrappedValue) { _, _ in
      handlePendingNavigation()
    }
    .onChange(of: navigateToComment?.wrappedValue?.id) { _, _ in
      if let model = diffModel {
        handleNavigateToComment(model)
      }
    }
    .onAppear {
      isCanvasFocused = true
      handlePendingNavigation()
      viewModel.loadReviewCommentsIfNeeded()
    }
  }

  // MARK: - File Section Header

  // MARK: - Comment Helpers

  /// Get all comments whose range ends at this line (so thread appears after the last selected line).
  /// Scoped to the active turn view — when viewing a specific turn, only shows that turn's comments.
  func commentsForLine(filePath: String, lineNum: Int) -> [ServerReviewComment] {
    ReviewCanvasProjection.commentsForLine(
      comments: viewModel.reviewComments,
      filePath: filePath,
      lineNum: lineNum,
      activeTurnId: selectedTurnDiffId
    )
  }

  /// Set of line indices within a hunk that fall in the mark-to-cursor selection range.
  func selectionLineIndices(fileIdx: Int, hunkIdx: Int) -> Set<Int> {
    ReviewCommentComposerPlanner.selectionLineIndices(
      mark: commentInteraction.commentMark,
      currentTarget: diffModel.flatMap { currentTarget($0) },
      model: diffModel,
      fileIndex: fileIdx,
      hunkIndex: hunkIdx
    )
  }

  // MARK: - Send Review to Model

  /// Send review comments as structured feedback to the model, then resolve them.
  /// If comments are selected (via `x`), sends only those. Otherwise sends all open.
  /// Records a review round to track which files the model modifies in response.
  func sendReview() {
    viewModel.sendReview(
      selectedCommentIds: &selectedCommentIds,
      selectedTurnDiffId: selectedTurnDiffId,
      diffModel: diffModel,
      reviewRoundTracker: &reviewRoundTracker
    )
  }

  // MARK: - Review Round Status

  /// Check if a file was reviewed and subsequently modified by the model.
  /// Returns: nil (not reviewed), false (reviewed but not yet modified), true (reviewed and addressed).
  func fileAddressedStatus(for filePath: String) -> Bool? {
    ReviewRoundTracker.addressedFileStatus(
      filePath: filePath,
      state: reviewRoundTracker,
      turnDiffs: viewModel.turnDiffs
    )
  }

  /// Set of file paths that were part of the last review round.
  var reviewedFilePaths: Set<String> {
    reviewRoundTracker.reviewedFilePaths
  }

  /// Set of file paths the model modified after the last review.
  var addressedFilePaths: Set<String> {
    ReviewRoundTracker.addressedFilePaths(
      state: reviewRoundTracker,
      turnDiffs: viewModel.turnDiffs
    )
  }

}
