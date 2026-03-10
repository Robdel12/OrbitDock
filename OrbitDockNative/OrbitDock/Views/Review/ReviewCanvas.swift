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
  let projectPath: String
  let isSessionActive: Bool
  var compact: Bool = false
  var navigateToFileId: Binding<String?>?
  var onDismiss: (() -> Void)?
  @Binding var selectedCommentIds: Set<String>
  var navigateToComment: Binding<ServerReviewComment?>?

  @Environment(SessionStore.self) var serverState

  @State var cursorIndex: Int = 0
  @State var collapsedFiles: Set<String> = []
  @State var collapsedHunks: Set<String> = []
  @State private var expandedContextBars: Set<String> = []
  @State var selectedTurnDiffId: String?
  @State var isFollowing = true
  @State private var previousFileCount = 0
  @FocusState private var isCanvasFocused: Bool

  // Comment interaction state
  @State var commentInteraction = ReviewCommentInteractionState()

  // Review round tracking — detects which files the model modified after feedback
  @State var reviewRoundTracker = ReviewRoundTrackerState()
  @State var showResolvedComments: Bool = false

  /// Diff parsing cache — avoids re-parsing on every body evaluation
  @State private var diffParseCache = ReviewDiffParseCache()

  var obs: SessionObservable {
    serverState.session(sessionId)
  }

  private var rawDiff: String? {
    ReviewCanvasStatePlanner.rawDiff(
      selectedTurnDiffId: selectedTurnDiffId,
      turnDiffs: obs.turnDiffs,
      currentDiff: obs.diff
    )
  }

  var diffModel: DiffModel? {
    diffParseCache.model(for: rawDiff)
  }

  private var commentCounts: [String: Int] {
    ReviewCanvasProjection.commentCounts(
      comments: obs.reviewComments,
      activeTurnId: selectedTurnDiffId
    )
  }

  var reviewSendBarState: ReviewSendBarState? {
    ReviewCanvasProjection.sendBarState(
      comments: obs.reviewComments,
      selectedCommentIds: selectedCommentIds,
      activeTurnId: selectedTurnDiffId
    )
  }

  var hasResolvedComments: Bool {
    ReviewCanvasProjection.hasResolvedComments(
      comments: obs.reviewComments,
      activeTurnId: selectedTurnDiffId
    )
  }

  var reviewBannerState: ReviewBannerState? {
    ReviewRoundTracker.bannerState(
      state: reviewRoundTracker,
      turnDiffs: obs.turnDiffs
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
      if ReviewCanvasStatePlanner.shouldLoadReviewComments(existingComments: obs.reviewComments) {
        Task { try? await serverState.listReviewComments(sessionId: sessionId, turnId: nil) }
      }
    }
  }

  // MARK: - Full Layout

  private func fullLayout(_ model: DiffModel) -> some View {
    HStack(spacing: 0) {
      FileListNavigator(
        files: model.files,
        turnDiffs: obs.turnDiffs,
        selectedFileId: fileListBinding(model),
        selectedTurnDiffId: $selectedTurnDiffId,
        commentCounts: commentCounts,
        addressedFiles: addressedFilePaths,
        reviewPendingFiles: reviewedFilePaths.subtracting(addressedFilePaths),
        showResolvedComments: $showResolvedComments,
        hasResolvedComments: hasResolvedComments
      )

      Divider()
        .foregroundStyle(Color.panelBorder)

      VStack(spacing: 0) {
        fullLayoutToolbar(model)
        unifiedDiffView(model)
      }
    }
  }

  // MARK: - Compact Layout

  private func compactLayout(_ model: DiffModel) -> some View {
    VStack(spacing: 0) {
      compactFileStrip(model)
      unifiedDiffView(model)
    }
  }

  // MARK: - Unified Diff View

  private func unifiedDiffView(_ model: DiffModel) -> some View {
    let targets = visibleTargets(model)
    let safeIdx = targets.isEmpty ? 0 : min(cursorIndex, targets.count - 1)
    let target = targets.isEmpty ? nil : targets[safeIdx]

    return ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: true) {
        ReviewCanvasDiffFiles(
          model: model,
          target: target,
          reviewComments: obs.reviewComments,
          selectedTurnDiffId: selectedTurnDiffId,
          showResolvedComments: showResolvedComments,
          selectedCommentIds: $selectedCommentIds,
          commentInteraction: $commentInteraction,
          collapsedFiles: $collapsedFiles,
          collapsedHunks: $collapsedHunks,
          expandedContextBars: $expandedContextBars,
          reviewBanner: {
            reviewBanner
          },
          fileHeader: { file, fileIndex, isCursor in
            fileSectionHeader(file: file, fileIndex: fileIndex, isCursor: isCursor)
          },
          onSelectFileHeader: { fileIndex in
            isFollowing = false
            if let index = targets.firstIndex(of: .fileHeader(fileIndex: fileIndex)) {
              cursorIndex = index
            }
          },
          onToggleFileCollapse: { fileIndex in
            toggleCollapseAtCursor(model: model, fileIdx: fileIndex)
          },
          onToggleHunkCollapse: { fileIndex, hunkIndex in
            toggleHunkCollapse(model: model, fileIdx: fileIndex, hunkIdx: hunkIndex)
          },
          mouseSelectionLineIndices: { fileIndex, hunkIndex in
            mouseSelectionLineIndices(fileIdx: fileIndex, hunkIdx: hunkIndex)
          },
          selectionLineIndices: { fileIndex, hunkIndex in
            selectionLineIndices(fileIdx: fileIndex, hunkIdx: hunkIndex)
          },
          composerLineRangeForHunk: { fileIndex, hunkIndex in
            composerLineRangeForHunk(fileIdx: fileIndex, hunkIdx: hunkIndex)
          },
          onLineComment: { fileIndex, hunkIndex, clickedLineIndex, smartRange in
            handleLineComment(
              fileIdx: fileIndex,
              hunkIdx: hunkIndex,
              clickedIdx: clickedLineIndex,
              smartRange: smartRange,
              model: model
            )
          },
          onLineDragChanged: { fileIndex, hunkIndex, anchor, current in
            handleLineDragChanged(fileIdx: fileIndex, hunkIdx: hunkIndex, anchor: anchor, current: current)
          },
          onLineDragEnded: { fileIndex, hunkIndex, startIndex, endIndex in
            handleLineDragEnded(
              fileIdx: fileIndex,
              hunkIdx: hunkIndex,
              startIdx: startIndex,
              endIdx: endIndex,
              model: model
            )
          },
          onSubmitComment: {
            submitComment()
          },
          onResolveComment: { comment in
            resolveComment(comment)
          }
        )
      }
      .onChange(of: cursorIndex) { _, newIdx in
        let currentTargets = visibleTargets(model)
        guard !currentTargets.isEmpty else { return }
        let safe = min(newIdx, currentTargets.count - 1)
        withAnimation(Motion.snappy) {
          proxy.scrollTo(currentTargets[safe].scrollId, anchor: .center)
        }
      }
    }
    .focusable()
    .focused($isCanvasFocused)
    .onKeyPress(keys: [.escape]) { _ in
      // Clear mark first, then composer — always consume to prevent closing review
      commentInteraction.cancelActiveInteraction()
      // Always handled: q is the close key, not Escape
      return .handled
    }
    .onKeyPress(keys: [.tab]) { _ in
      guard !commentInteraction.hasComposer else { return .ignored }
      guard let model = diffModel else { return .ignored }
      let target = currentTarget(model)
      switch target {
        case let .fileHeader(f):
          toggleCollapseAtCursor(model: model, fileIdx: f)
        case let .hunkHeader(f, h):
          toggleHunkCollapse(model: model, fileIdx: f, hunkIdx: h)
        case let .diffLine(f, h, _):
          toggleHunkCollapse(model: model, fileIdx: f, hunkIdx: h)
        case nil:
          break
      }
      return .handled
    }
    .onKeyPress(keys: [.return]) { _ in
      guard !commentInteraction.hasComposer else { return .ignored }
      guard let model = diffModel, let file = currentFile(model) else { return .ignored }
      openFileInEditor(file)
      return .handled
    }
    .onKeyPress { keyPress in
      guard !commentInteraction.hasComposer else { return .ignored }
      guard let model = diffModel else { return .ignored }
      return handleKeyPress(keyPress, model: model)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      if reviewSendBarState != nil {
        sendReviewBar
      }
    }
  }

  // MARK: - File Section Header

  // MARK: - Comment Helpers

  /// Get all comments whose range ends at this line (so thread appears after the last selected line).
  /// Scoped to the active turn view — when viewing a specific turn, only shows that turn's comments.
  func commentsForLine(filePath: String, lineNum: Int) -> [ServerReviewComment] {
    ReviewCanvasProjection.commentsForLine(
      comments: obs.reviewComments,
      filePath: filePath,
      lineNum: lineNum,
      activeTurnId: selectedTurnDiffId
    )
  }

  /// Set of line indices within a hunk that fall in the mark-to-cursor selection range.
  private func selectionLineIndices(fileIdx: Int, hunkIdx: Int) -> Set<Int> {
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
    let openComments = ReviewCanvasProjection.openComments(
      from: obs.reviewComments,
      activeTurnId: selectedTurnDiffId
    )

    guard let plan = ReviewSendCoordinator.makePlan(
      openComments: openComments,
      selectedCommentIds: selectedCommentIds,
      diffModel: diffModel,
      turnDiffs: obs.turnDiffs
    ) else { return }

    reviewRoundTracker.record(plan.reviewRound)

    Task {
      try? await serverState.sendMessage(sessionId: sessionId, content: plan.message)
    }

    // Mark sent comments as resolved
    for commentId in plan.commentIdsToResolve {
      Task {
        try? await serverState.clients.approvals.updateReviewComment(
          commentId: commentId,
          body: ApprovalsClient.UpdateReviewCommentRequest(status: .resolved)
        )
      }
    }

    // Clear selection after send
    selectedCommentIds.removeAll()
  }

  // MARK: - Review Round Status

  /// Check if a file was reviewed and subsequently modified by the model.
  /// Returns: nil (not reviewed), false (reviewed but not yet modified), true (reviewed and addressed).
  func fileAddressedStatus(for filePath: String) -> Bool? {
    ReviewRoundTracker.addressedFileStatus(
      filePath: filePath,
      state: reviewRoundTracker,
      turnDiffs: obs.turnDiffs
    )
  }

  /// Set of file paths that were part of the last review round.
  private var reviewedFilePaths: Set<String> {
    reviewRoundTracker.reviewedFilePaths
  }

  /// Set of file paths the model modified after the last review.
  private var addressedFilePaths: Set<String> {
    ReviewRoundTracker.addressedFilePaths(
      state: reviewRoundTracker,
      turnDiffs: obs.turnDiffs
    )
  }

}
