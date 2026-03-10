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
    if let turnId = selectedTurnDiffId {
      return obs.turnDiffs.first(where: { $0.turnId == turnId })?.diff
    }
    return cumulativeDiff
  }

  private var cumulativeDiff: String? {
    var parts: [String] = []
    for td in obs.turnDiffs {
      parts.append(td.diff)
    }
    if let current = obs.diff, !current.isEmpty {
      if obs.turnDiffs.last?.diff != current {
        parts.append(current)
      }
    }
    let combined = parts.joined(separator: "\n")
    return combined.isEmpty ? nil : combined
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
      let newFileCount = model.files.count

      cursorIndex = ReviewCursorNavigation.clampedCursorIndex(cursorIndex: cursorIndex, targets: targets)
      if let followIndex = ReviewCursorNavigation.autoFollowFileHeaderIndex(
        isFollowing: isFollowing,
        isSessionActive: isSessionActive,
        previousFileCount: previousFileCount,
        newFileCount: newFileCount,
        targets: targets
      ) {
        cursorIndex = followIndex
      }

      previousFileCount = newFileCount
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
      if obs.reviewComments.isEmpty {
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
        LazyVStack(alignment: .leading, spacing: 0) {
          // Review round status banner
          reviewBanner

          ForEach(Array(model.files.enumerated()), id: \.element.id) { fileIdx, file in
            fileSectionHeader(
              file: file,
              fileIndex: fileIdx,
              isCursor: target == .fileHeader(fileIndex: fileIdx)
            )
            .id("file-\(fileIdx)")
            .onTapGesture {
              isFollowing = false
              // Move cursor to this file header
              if let idx = targets.firstIndex(of: .fileHeader(fileIndex: fileIdx)) {
                cursorIndex = idx
              }
              toggleCollapseAtCursor(model: model, fileIdx: fileIdx)
            }

            if !collapsedFiles.contains(file.id) {
              let language = ToolCardStyle.detectLanguage(from: file.newPath)
              let groupedResolved = groupedResolvedComments(forFile: file.newPath)

              ForEach(Array(file.hunks.enumerated()), id: \.element.id) { hunkIdx, hunk in
                if hunkIdx > 0 {
                  let gap = gapBetweenHunks(prev: file.hunks[hunkIdx - 1], current: hunk)
                  if gap > 0 {
                    let barKey = "\(fileIdx)-\(hunkIdx)"
                    ContextCollapseBar(
                      hiddenLineCount: gap,
                      isExpanded: Binding(
                        get: { expandedContextBars.contains(barKey) },
                        set: { val in
                          if val { expandedContextBars.insert(barKey) }
                          else { expandedContextBars.remove(barKey) }
                        }
                      )
                    )
                  }
                }

                let hunkKey = "\(fileIdx)-\(hunkIdx)"
                let isHunkCollapsed = collapsedHunks.contains(hunkKey)

                DiffHunkView(
                  hunk: hunk,
                  language: language,
                  hunkIndex: hunk.id,
                  fileIndex: fileIdx,
                  cursorLineIndex: ReviewCursorNavigation.cursorLineForHunk(
                    fileIndex: fileIdx,
                    hunkIndex: hunkIdx,
                    target: target
                  ),
                  isCursorOnHeader: ReviewCursorNavigation.isCursorOnHunkHeader(
                    fileIndex: fileIdx,
                    hunkIndex: hunkIdx,
                    target: target
                  ),
                  isHunkCollapsed: isHunkCollapsed,
                  commentedLines: commentedNewLineNums(forFile: file.newPath),
                  selectionLines: mouseSelectionLineIndices(fileIdx: fileIdx, hunkIdx: hunkIdx)
                    .union(selectionLineIndices(fileIdx: fileIdx, hunkIdx: hunkIdx)),
                  composerLineRange: composerLineRangeForHunk(fileIdx: fileIdx, hunkIdx: hunkIdx),
                  onLineComment: { clickedIdx, smartRange in
                    handleLineComment(
                      fileIdx: fileIdx,
                      hunkIdx: hunkIdx,
                      clickedIdx: clickedIdx,
                      smartRange: smartRange,
                      model: model
                    )
                  },
                  onLineDragChanged: { anchor, current in
                    handleLineDragChanged(fileIdx: fileIdx, hunkIdx: hunkIdx, anchor: anchor, current: current)
                  },
                  onLineDragEnded: { startIdx, endIdx in
                    handleLineDragEnded(
                      fileIdx: fileIdx,
                      hunkIdx: hunkIdx,
                      startIdx: startIdx,
                      endIdx: endIdx,
                      model: model
                    )
                  }
                ) { lineIdx, line in
                  // Inline comments: open → full thread, resolved → grouped marker
                  if let newLine = line.newLineNum {
                    // Open comments: per-line interactive threads
                    let openComments = commentsForLine(filePath: file.newPath, lineNum: newLine)
                      .filter { $0.status == .open }

                    if !openComments.isEmpty {
                      InlineCommentThread(
                        comments: openComments,
                        selectedIds: selectedCommentIds,
                        onResolve: { comment in
                          resolveComment(comment)
                        },
                        onToggleSelection: { comment in
                          if selectedCommentIds.contains(comment.id) {
                            selectedCommentIds.remove(comment.id)
                          } else {
                            selectedCommentIds.insert(comment.id)
                          }
                        }
                      )
                      .id("comments-\(fileIdx)-\(hunkIdx)-\(lineIdx)")
                    }

                    // Resolved comments: grouped by proximity — adjacent comments merge
                    // into a single marker at the last line of the group
                    if let resolvedGroup = groupedResolved[newLine] {
                      ResolvedCommentMarker(
                        comments: resolvedGroup,
                        onReopen: { comment in
                          resolveComment(comment)
                        },
                        startExpanded: showResolvedComments
                      )
                      .id("resolved-\(fileIdx)-\(hunkIdx)-\(lineIdx)")
                    }
                  }

                  // Composer (appears after last line of selection)
                  if let ct = commentInteraction.composerTarget,
                     ct.fileIndex == fileIdx,
                     ct.hunkIndex == hunkIdx,
                     ct.lineEndIdx == lineIdx
                  {
                    let fileName = ct.filePath.components(separatedBy: "/").last ?? ct.filePath
                    let lineLabel = ct.lineEnd.map { end in
                      end != ct.lineStart ? "Lines \(ct.lineStart)–\(end)" : "Line \(ct.lineStart)"
                    } ?? "Line \(ct.lineStart)"

                    CommentComposerView(
                      commentBody: $commentInteraction.composerBody,
                      tag: $commentInteraction.composerTag,
                      fileName: fileName,
                      lineLabel: lineLabel,
                      onSubmit: { submitComment() },
                      onCancel: { commentInteraction.clearComposer() }
                    )
                    .id("composer-\(fileIdx)-\(hunkIdx)-\(lineIdx)")
                  }
                }
              }
            }
          }

          Color.clear.frame(height: Spacing.xxl)
        }
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

  /// Group resolved comments by proximity — adjacent lineEnd values merge into a single marker.
  /// Returns a map of newLineNum → [comments] where the key is the last line in each contiguous group.
  private func groupedResolvedComments(forFile filePath: String) -> [Int: [ServerReviewComment]] {
    ReviewCanvasProjection.groupedResolvedComments(
      comments: obs.reviewComments,
      filePath: filePath,
      activeTurnId: selectedTurnDiffId
    )
  }

  /// Set of new-side line numbers that have comments for a given file.
  /// In normal mode, only marks open comments. In history mode, marks all.
  private func commentedNewLineNums(forFile filePath: String) -> Set<Int> {
    ReviewCanvasProjection.commentedNewLineNums(
      comments: obs.reviewComments,
      filePath: filePath,
      activeTurnId: selectedTurnDiffId,
      showResolvedComments: showResolvedComments
    )
  }

  /// Whether a comment matches the currently active turn view.
  /// "All Changes" view shows all comments; per-turn view shows only that turn's comments
  /// (plus comments with no turn, which are global).
  private func commentMatchesTurnView(_ comment: ServerReviewComment) -> Bool {
    ReviewCanvasProjection.commentMatchesTurnView(comment, activeTurnId: selectedTurnDiffId)
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

  // MARK: - Mouse Interactions

  /// Handle click on the + comment button — uses smart connected block range.
  private func handleLineComment(
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
  private func handleLineDragChanged(fileIdx: Int, hunkIdx: Int, anchor: Int, current: Int) {
    commentInteraction.beginMouseDrag(
      fileIndex: fileIdx,
      hunkIndex: hunkIdx,
      anchorLineIndex: anchor,
      currentLineIndex: current
    )
  }

  /// Handle drag end — open composer for the dragged range.
  private func handleLineDragEnded(fileIdx: Int, hunkIdx: Int, startIdx: Int, endIdx: Int, model: DiffModel) {
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
  private func composerLineRangeForHunk(fileIdx: Int, hunkIdx: Int) -> ClosedRange<Int>? {
    ReviewCommentComposerPlanner.composerLineRange(
      composerTarget: commentInteraction.composerTarget,
      fileIndex: fileIdx,
      hunkIndex: hunkIdx
    )
  }

  /// Line indices within a hunk that fall in the mouse drag selection.
  private func mouseSelectionLineIndices(fileIdx: Int, hunkIdx: Int) -> Set<Int> {
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

  // MARK: - Compact File Strip

  // MARK: - Navigation Helpers

  private func handlePendingNavigation() {
    guard let fileId = navigateToFileId?.wrappedValue, !fileId.isEmpty else { return }
    if let model = diffModel {
      if let fileIdx = model.files.firstIndex(where: {
        $0.id == fileId || $0.newPath == fileId
          || $0.newPath.hasSuffix(fileId) || fileId.hasSuffix($0.newPath)
      }) {
        let targets = visibleTargets(model)
        if let idx = targets.firstIndex(of: .fileHeader(fileIndex: fileIdx)) {
          cursorIndex = idx
        }
      }
    }
    navigateToFileId?.wrappedValue = nil
  }

  /// Binding adapter for FileListNavigator — maps cursor to/from file ID.
  private func fileListBinding(_ model: DiffModel) -> Binding<String?> {
    Binding<String?>(
      get: {
        let fileIdx = currentFileIndex(model)
        return fileIdx < model.files.count ? model.files[fileIdx].id : nil
      },
      set: { newId in
        if let id = newId, let fileIdx = model.files.firstIndex(where: { $0.id == id }) {
          isFollowing = false
          let targets = visibleTargets(model)
          if let idx = targets.firstIndex(of: .fileHeader(fileIndex: fileIdx)) {
            cursorIndex = idx
          }
        }
      }
    )
  }

  // MARK: - Helpers

  private func gapBetweenHunks(prev: DiffHunk, current: DiffHunk) -> Int {
    let prevEnd = prev.oldStart + prev.oldCount
    let currentStart = current.oldStart
    return max(0, currentStart - prevEnd)
  }

  @AppStorage("preferredEditor") private var preferredEditor: String = ""

  private func openFileInEditor(_ file: FileDiff) {
    let fullPath = projectPath.hasSuffix("/")
      ? projectPath + file.newPath
      : projectPath + "/" + file.newPath

    guard !preferredEditor.isEmpty else {
      _ = Platform.services.openURL(URL(fileURLWithPath: fullPath))
      return
    }

    #if !os(macOS)
      _ = Platform.services.openURL(URL(fileURLWithPath: fullPath))
      return
    #else
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [preferredEditor, fullPath]
      try? process.run()
    #endif
  }
}
