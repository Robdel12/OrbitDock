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

  @Environment(SessionStore.self) private var serverState

  @State private var cursorIndex: Int = 0
  @State private var collapsedFiles: Set<String> = []
  @State private var collapsedHunks: Set<String> = []
  @State private var expandedContextBars: Set<String> = []
  @State private var selectedTurnDiffId: String?
  @State private var isFollowing = true
  @State private var previousFileCount = 0
  @FocusState private var isCanvasFocused: Bool

  // Comment interaction state
  @State private var commentInteraction = ReviewCommentInteractionState()

  // Review round tracking — detects which files the model modified after feedback
  @State private var reviewRoundTracker = ReviewRoundTrackerState()
  @State private var showResolvedComments: Bool = false

  /// Diff parsing cache — avoids re-parsing on every body evaluation
  @State private var diffParseCache = ReviewDiffParseCache()

  private var obs: SessionObservable {
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

  private var diffModel: DiffModel? {
    diffParseCache.model(for: rawDiff)
  }

  private var commentCounts: [String: Int] {
    ReviewCanvasProjection.commentCounts(
      comments: obs.reviewComments,
      activeTurnId: selectedTurnDiffId
    )
  }

  private var reviewSendBarState: ReviewSendBarState? {
    ReviewCanvasProjection.sendBarState(
      comments: obs.reviewComments,
      selectedCommentIds: selectedCommentIds,
      activeTurnId: selectedTurnDiffId
    )
  }

  private var hasResolvedComments: Bool {
    ReviewCanvasProjection.hasResolvedComments(
      comments: obs.reviewComments,
      activeTurnId: selectedTurnDiffId
    )
  }

  private var reviewBannerState: ReviewBannerState? {
    ReviewRoundTracker.bannerState(
      state: reviewRoundTracker,
      turnDiffs: obs.turnDiffs
    )
  }

  // MARK: - Cursor Helpers

  private func visibleTargets(_ model: DiffModel) -> [ReviewCursorTarget] {
    ReviewCursorNavigation.visibleTargets(
      in: model,
      collapsedFiles: collapsedFiles,
      collapsedHunks: collapsedHunks
    )
  }

  private func currentTarget(_ model: DiffModel) -> ReviewCursorTarget? {
    ReviewCursorNavigation.currentTarget(cursorIndex: cursorIndex, targets: visibleTargets(model))
  }

  private func currentFileIndex(_ model: DiffModel) -> Int {
    ReviewCursorNavigation.currentFileIndex(target: currentTarget(model))
  }

  private func currentFile(_ model: DiffModel) -> FileDiff? {
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

  // MARK: - Full Layout Toolbar

  private func fullLayoutToolbar(_ model: DiffModel) -> some View {
    let totalAdds = model.files.reduce(0) { $0 + $1.stats.additions }
    let totalDels = model.files.reduce(0) { $0 + $1.stats.deletions }

    return HStack(spacing: Spacing.sm) {
      // Current file indicator
      if let file = currentFile(model) {
        let fileName = file.newPath.components(separatedBy: "/").last ?? file.newPath
        Text(fileName)
          .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
          .foregroundStyle(.primary.opacity(0.8))
          .lineLimit(1)
      }

      Spacer()

      // History toggle
      if hasResolvedComments {
        Button {
          withAnimation(Motion.snappy) {
            showResolvedComments.toggle()
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: showResolvedComments ? "eye.fill" : "eye.slash")
              .font(.system(size: TypeScale.micro, weight: .medium))
            Text("History")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(showResolvedComments ? Color.statusQuestion : Color.white.opacity(0.3))
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(
            showResolvedComments ? Color.statusQuestion.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          )
        }
        .buttonStyle(.plain)
      }

      // Follow indicator
      if isSessionActive {
        Button {
          isFollowing.toggle()
          if isFollowing,
             let lastFile = ReviewCursorNavigation.autoFollowFileHeaderIndex(
               isFollowing: true,
               isSessionActive: true,
               previousFileCount: 0,
               newFileCount: model.files.count,
               targets: visibleTargets(model)
             )
          {
            cursorIndex = lastFile
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Circle()
              .fill(isFollowing ? Color.accent : Color.white.opacity(0.2))
              .frame(width: 5, height: 5)
            Text(isFollowing ? "Following" : "Paused")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(isFollowing ? Color.accent : Color.white.opacity(0.3))
          }
        }
        .buttonStyle(.plain)
      }

      // Stats
      HStack(spacing: Spacing.xs) {
        Text("+\(totalAdds)")
          .foregroundStyle(Color.diffAddedAccent.opacity(0.8))
        Text("\u{2212}\(totalDels)")
          .foregroundStyle(Color.diffRemovedAccent.opacity(0.8))
      }
      .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundSecondary)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.panelBorder)
        .frame(height: 1)
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

  @ViewBuilder
  private var sendReviewBar: some View {
    if let reviewSendBarState {
      HStack(spacing: Spacing.sm) {
      // Clear selection button (only when selection active)
        if reviewSendBarState.hasSelection {
        Button {
          selectedCommentIds.removeAll()
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "xmark")
              .font(.system(size: TypeScale.micro, weight: .bold))
              Text("\(reviewSendBarState.selectedCommentCount) selected")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(.white.opacity(0.7))
          .padding(.horizontal, Spacing.md_)
          .padding(.vertical, Spacing.sm)
          .background(.white.opacity(OpacityTier.light), in: Capsule())
        }
        .buttonStyle(.plain)
      }

        Button(action: sendReview) {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "paperplane.fill")
              .font(.system(size: TypeScale.body, weight: .medium))

            Text(reviewSendBarState.label)
              .font(.system(size: TypeScale.code, weight: .semibold))

            Text("S")
              .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
              .foregroundStyle(.white.opacity(0.5))
              .padding(.horizontal, 5)
              .padding(.vertical, Spacing.xxs)
              .background(.white.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.sm))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.sm)
          .background(Color.statusQuestion, in: Capsule())
          .themeShadow(Shadow.md)
        }
        .buttonStyle(.plain)
      }
      .padding(.bottom, Spacing.lg)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .animation(Motion.gentle, value: reviewSendBarState.sendCount)
    }
  }

  // MARK: - File Section Header

  private func fileSectionHeader(file: FileDiff, fileIndex: Int, isCursor: Bool) -> some View {
    let isCollapsed = collapsedFiles.contains(file.id)

    return HStack(spacing: 0) {
      // Cursor indicator — accent left bar
      Rectangle()
        .fill(isCursor ? Color.accent : Color.clear)
        .frame(width: EdgeBar.width)

      // Collapse chevron
      Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(isCursor ? Color.accent : Color.white.opacity(0.25))
        .frame(width: Spacing.xl)

      // Change type icon
      ZStack {
        Circle()
          .fill(changeTypeColor(file.changeType).opacity(OpacityTier.light))
          .frame(width: 22, height: 22)
        Image(systemName: fileIcon(file.changeType))
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(changeTypeColor(file.changeType))
      }
      .padding(.trailing, Spacing.sm)

      // File path — dir dimmed, filename bold
      filePathLabel(file.newPath)
        .padding(.trailing, Spacing.sm)

      // Stats badge
      HStack(spacing: Spacing.sm_) {
        if file.stats.additions > 0 {
          HStack(spacing: Spacing.xxs) {
            Text("+")
              .foregroundStyle(Color.diffAddedAccent.opacity(0.7))
            Text("\(file.stats.additions)")
              .foregroundStyle(Color.diffAddedAccent)
          }
        }
        if file.stats.deletions > 0 {
          HStack(spacing: Spacing.xxs) {
            Text("\u{2212}")
              .foregroundStyle(Color.diffRemovedAccent.opacity(0.7))
            Text("\(file.stats.deletions)")
              .foregroundStyle(Color.diffRemovedAccent)
          }
        }
      }
      .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))

      // Review status badge
      if let addressed = fileAddressedStatus(for: file.newPath) {
        HStack(spacing: Spacing.gap) {
          Image(systemName: addressed ? "checkmark" : "clock")
            .font(.system(size: 8, weight: .bold))
          Text(addressed ? "Updated" : "In review")
            .font(.system(size: TypeScale.micro, weight: .semibold))
        }
        .foregroundStyle(addressed ? Color.accent : Color.statusQuestion)
        .padding(.horizontal, Spacing.sm_)
        .padding(.vertical, Spacing.xxs)
        .background(
          (addressed ? Color.accent : Color.statusQuestion).opacity(OpacityTier.light),
          in: Capsule()
        )
      }

      Spacer(minLength: Spacing.lg)

      // Collapsed hunk count hint
      if isCollapsed {
        Text("\(file.hunks.count) hunk\(file.hunks.count == 1 ? "" : "s")")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)
          .padding(.trailing, Spacing.sm)
      }
    }
    .padding(.vertical, Spacing.sm)
    .padding(.trailing, Spacing.sm)
    .background(isCursor ? Color.accent.opacity(OpacityTier.light) : Color.backgroundSecondary)
    .contentShape(Rectangle())
  }

  private func filePathLabel(_ path: String) -> some View {
    let components = path.components(separatedBy: "/")
    let fileName = components.last ?? path
    let dirPath = components.count > 1 ? components.dropLast().joined(separator: "/") + "/" : ""

    return HStack(spacing: 0) {
      if !dirPath.isEmpty {
        Text(dirPath)
          .font(.system(size: TypeScale.body, weight: .regular, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
      Text(fileName)
        .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
        .foregroundStyle(.primary)
    }
    .lineLimit(1)
  }

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

  private func handleKeyPress(_ keyPress: KeyPress, model: DiffModel) -> KeyPress.Result {
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
      // n / p — section navigation (file headers + hunk headers)
      case "n":
        jumpToNextHunk(forward: true, in: model)
        return .handled

      case "p":
        jumpToNextHunk(forward: false, in: model)
        return .handled

      // c — open comment composer
      case "c":
        return openComposer(model: model)

      // ] — jump to next unresolved comment
      case "]":
        jumpToNextComment(forward: true, in: model)
        return .handled

      // [ — jump to previous unresolved comment
      case "[":
        jumpToNextComment(forward: false, in: model)
        return .handled

      // r — toggle resolve on comment at cursor
      case "r":
        resolveCommentAtCursor(model: model)
        return .handled

      // x — toggle selection on comment at cursor
      case "x":
        toggleSelectionAtCursor(model: model)
        return .handled

      // q — dismiss review pane
      case "q":
        onDismiss?()
        return onDismiss != nil ? .handled : .ignored

      // f — toggle follow mode
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

  /// Move cursor by delta lines (C-n/C-p — line-by-line).
  private func moveCursor(by delta: Int, in model: DiffModel) {
    let targets = visibleTargets(model)
    guard let nextIndex = ReviewCursorNavigation.movedCursor(
      currentIndex: cursorIndex,
      delta: delta,
      targets: targets
    ) else { return }
    isFollowing = false
    cursorIndex = nextIndex
  }

  /// Jump cursor to next/prev section header — file headers + hunk headers.
  private func jumpToNextHunk(forward: Bool, in model: DiffModel) {
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

  /// Toggle collapse of the file at the given file index, repositioning cursor to the file header.
  private func toggleCollapseAtCursor(model: DiffModel, fileIdx: Int) {
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

  /// Toggle collapse of a specific hunk, repositioning cursor to the hunk header.
  private func toggleHunkCollapse(model: DiffModel, fileIdx: Int, hunkIdx: Int) {
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

  // MARK: - Comment Helpers

  /// Get all comments whose range ends at this line (so thread appears after the last selected line).
  /// Scoped to the active turn view — when viewing a specific turn, only shows that turn's comments.
  private func commentsForLine(filePath: String, lineNum: Int) -> [ServerReviewComment] {
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
  private func openComposer(model: DiffModel) -> KeyPress.Result {
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

  /// Submit the current comment to the server.
  /// Associates the comment with the correct turn diff — either the one being viewed,
  /// or auto-inferred from the file when on "All Changes" view.
  private func submitComment() {
    guard let ct = commentInteraction.composerTarget else { return }
    let trimmed = commentInteraction.composerBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Smart turn association: if viewing "All Changes", find the latest turn that
    // modified this file so the comment shows up on the correct edit turn.
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

  /// Resolve/unresolve a comment.
  private func resolveComment(_ comment: ServerReviewComment) {
    let newStatus: ServerReviewCommentStatus = comment.status == .open ? .resolved : .open
    Task {
      try? await serverState.clients.approvals.updateReviewComment(
        commentId: comment.id,
        body: ApprovalsClient.UpdateReviewCommentRequest(status: newStatus)
      )
    }
  }

  /// Toggle resolve on the first open comment at the current cursor line.
  private func resolveCommentAtCursor(model: DiffModel) {
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

  /// Toggle selection on the open comment at cursor for partial sends.
  private func toggleSelectionAtCursor(model: DiffModel) {
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

  /// Jump cursor to the next/prev diff line that has an unresolved comment.
  private func jumpToNextComment(forward: Bool, in model: DiffModel) {
    let targets = visibleTargets(model)
    guard !targets.isEmpty else { return }
    let safeIdx = min(cursorIndex, targets.count - 1)

    let unresolvedFiles = buildUnresolvedCommentLineMap(model: model)

    let range = forward
      ? Array((safeIdx + 1) ..< targets.count) + Array(0 ..< safeIdx)
      : (Array(stride(from: safeIdx - 1, through: 0, by: -1)) + Array(stride(
        from: targets.count - 1,
        through: safeIdx + 1,
        by: -1
      )))

    for i in range {
      guard case let .diffLine(f, h, l) = targets[i] else { continue }
      let file = model.files[f]
      let line = file.hunks[h].lines[l]
      guard let newLine = line.newLineNum else { continue }

      if let fileSet = unresolvedFiles[file.newPath], fileSet.contains(newLine) {
        // Auto-expand collapsed file/hunk
        let fileId = file.id
        if collapsedFiles.contains(fileId) {
          _ = withAnimation(Motion.snappy) {
            collapsedFiles.remove(fileId)
          }
        }
        let hunkKey = "\(f)-\(h)"
        if collapsedHunks.contains(hunkKey) {
          _ = withAnimation(Motion.snappy) {
            collapsedHunks.remove(hunkKey)
          }
        }

        // Recompute targets after expansion and find the right index
        let newTargets = visibleTargets(model)
        if let newIdx = newTargets.firstIndex(of: .diffLine(fileIndex: f, hunkIndex: h, lineIndex: l)) {
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

  /// Build a map of filePath → Set<newLineNum> for unresolved comments.
  /// Respects the active turn view scope.
  private func buildUnresolvedCommentLineMap(model _: DiffModel) -> [String: Set<Int>] {
    ReviewCanvasProjection.unresolvedCommentLineMap(
      comments: obs.reviewComments,
      activeTurnId: selectedTurnDiffId
    )
  }

  // MARK: - Navigate to Comment

  private func handleNavigateToComment(_ model: DiffModel) {
    guard let comment = navigateToComment?.wrappedValue else { return }

    // Find the file
    guard let fileIdx = model.files.firstIndex(where: { $0.newPath == comment.filePath }) else { return }
    let file = model.files[fileIdx]

    // Expand file if collapsed
    if collapsedFiles.contains(file.id) {
      _ = withAnimation(Motion.snappy) {
        collapsedFiles.remove(file.id)
      }
    }

    // Find the hunk and line
    for (hunkIdx, hunk) in file.hunks.enumerated() {
      for (lineIdx, line) in hunk.lines.enumerated() {
        if let newLine = line.newLineNum, newLine == Int(comment.lineStart) {
          // Expand hunk if collapsed
          let hunkKey = "\(fileIdx)-\(hunkIdx)"
          if collapsedHunks.contains(hunkKey) {
            _ = withAnimation(Motion.snappy) {
              collapsedHunks.remove(hunkKey)
            }
          }

          // Move cursor
          let targets = visibleTargets(model)
          if let idx = targets.firstIndex(of: .diffLine(fileIndex: fileIdx, hunkIndex: hunkIdx, lineIndex: lineIdx)) {
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

  // MARK: - Send Review to Model

  /// Send review comments as structured feedback to the model, then resolve them.
  /// If comments are selected (via `x`), sends only those. Otherwise sends all open.
  /// Records a review round to track which files the model modifies in response.
  private func sendReview() {
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

  // MARK: - Review Banner

  @ViewBuilder
  private var reviewBanner: some View {
    if let reviewBannerState {
      let accentColor = reviewBannerState.tone == .progress ? Color.accent : Color.statusQuestion

      HStack(spacing: 0) {
        // Left accent bar
        Rectangle()
          .fill(accentColor)
          .frame(width: 3)

        HStack(spacing: Spacing.sm) {
          // Status icon
          Image(systemName: reviewBannerState.iconName)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(accentColor)

          // Status text
          Text(reviewBannerState.title)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(.primary.opacity(OpacityTier.vivid))

          if let detail = reviewBannerState.detail {
            Text(detail)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
          }

          Spacer()

          // Dismiss button
          Button {
            withAnimation(Motion.hover) {
              reviewRoundTracker.dismissBanner()
            }
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(Color.textQuaternary)
              .padding(Spacing.xs)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
      }
      .background(accentColor.opacity(OpacityTier.tint))
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(accentColor.opacity(OpacityTier.light))
          .frame(height: 1)
      }
      .transition(.asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity),
        removal: .opacity
      ))
    }
  }

  // MARK: - Review Round Status

  /// Check if a file was reviewed and subsequently modified by the model.
  /// Returns: nil (not reviewed), false (reviewed but not yet modified), true (reviewed and addressed).
  private func fileAddressedStatus(for filePath: String) -> Bool? {
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

  /// Infer which turn a comment belongs to by finding the latest turn that touched the file.
  /// Used when commenting on "All Changes" — maps the comment to the right edit turn.
  private func inferTurnId(forFile filePath: String) -> String? {
    for turnDiff in obs.turnDiffs.reversed() {
      if ReviewWorkflow.diffMentionsFile(turnDiff.diff, filePath: filePath) {
        return turnDiff.turnId
      }
    }
    return nil
  }

  // MARK: - Compact File Strip

  private func compactFileStrip(_ model: DiffModel) -> some View {
    let cursorFileIdx = currentFileIndex(model)

    return VStack(spacing: 0) {
      // Source selector row
      if !obs.turnDiffs.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Spacing.xs) {
            compactSourceButton(
              label: "All Changes",
              icon: "square.stack.3d.up",
              isSelected: selectedTurnDiffId == nil
            ) {
              selectedTurnDiffId = nil
            }

            ForEach(Array(obs.turnDiffs.enumerated()), id: \.element.turnId) { index, turnDiff in
              compactSourceButton(
                label: "Edit \(index + 1)",
                icon: "number",
                isSelected: selectedTurnDiffId == turnDiff.turnId
              ) {
                selectedTurnDiffId = turnDiff.turnId
              }
            }
          }
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
        }
        .background(Color.backgroundSecondary)

        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.5))
      }

      // File chips row
      HStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Spacing.xs) {
            ForEach(Array(model.files.enumerated()), id: \.element.id) { idx, file in
              fileChip(file, isSelected: idx == cursorFileIdx)
                .onTapGesture {
                  isFollowing = false
                  let targets = visibleTargets(model)
                  if let targetIdx = targets.firstIndex(of: .fileHeader(fileIndex: idx)) {
                    cursorIndex = targetIdx
                  }
                }
            }
          }
          .padding(.horizontal, Spacing.sm)
        }

        // Right edge: follow toggle + stats
        HStack(spacing: Spacing.sm_) {
          Divider()
            .frame(height: Spacing.lg)
            .foregroundStyle(Color.panelBorder)

          // Show/hide resolved comments toggle
          if hasResolvedComments {
            Button {
              withAnimation(Motion.snappy) {
                showResolvedComments.toggle()
              }
            } label: {
              HStack(spacing: Spacing.xs) {
                Image(systemName: showResolvedComments ? "eye.fill" : "eye.slash")
                  .font(.system(size: 8, weight: .medium))
                Text(showResolvedComments ? "History" : "History")
                  .font(.system(size: TypeScale.micro, weight: .medium))
              }
              .foregroundStyle(showResolvedComments ? Color.statusQuestion : Color.white.opacity(0.3))
            }
            .buttonStyle(.plain)

            Divider()
              .frame(height: Spacing.md)
              .foregroundStyle(Color.panelBorder)
          }

          if isSessionActive {
            Button {
              isFollowing.toggle()
              if isFollowing, let model = diffModel {
                let targets = visibleTargets(model)
                if let lastFile = targets.lastIndex(where: { $0.isFileHeader }) {
                  cursorIndex = lastFile
                }
              }
            } label: {
              HStack(spacing: Spacing.xs) {
                Circle()
                  .fill(isFollowing ? Color.accent : Color.white.opacity(0.2))
                  .frame(width: 5, height: 5)
                Text(isFollowing ? "Following" : "Paused")
                  .font(.system(size: TypeScale.micro, weight: .medium))
                  .foregroundStyle(isFollowing ? Color.accent : Color.white.opacity(0.3))
              }
            }
            .buttonStyle(.plain)
          }

          let totalAdds = model.files.reduce(0) { $0 + $1.stats.additions }
          let totalDels = model.files.reduce(0) { $0 + $1.stats.deletions }

          HStack(spacing: Spacing.xs) {
            Text("+\(totalAdds)")
              .foregroundStyle(Color.diffAddedAccent.opacity(0.8))
            Text("\u{2212}\(totalDels)")
              .foregroundStyle(Color.diffRemovedAccent.opacity(0.8))
          }
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
        }
        .padding(.trailing, Spacing.sm)
      }
      .padding(.vertical, Spacing.sm)
    }
    .background(Color.backgroundSecondary)
  }

  private func fileChip(_ file: FileDiff, isSelected: Bool) -> some View {
    let fileName = file.newPath.components(separatedBy: "/").last ?? file.newPath
    let changeColor = chipColor(file.changeType)
    let reviewStatus = fileAddressedStatus(for: file.newPath)

    return HStack(spacing: Spacing.xs) {
      // Review status dot — tiny indicator overlaid on the change bar
      if let addressed = reviewStatus {
        Circle()
          .fill(addressed ? Color.accent : Color.statusQuestion)
          .frame(width: 5, height: 5)
      } else {
        RoundedRectangle(cornerRadius: 1)
          .fill(changeColor)
          .frame(width: 2, height: Spacing.lg_)
      }

      Text(fileName)
        .font(.system(size: TypeScale.caption, weight: isSelected ? .semibold : .medium, design: .monospaced))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .lineLimit(1)

      if file.stats.additions + file.stats.deletions > 0 {
        HStack(spacing: 0) {
          if file.stats.additions > 0 {
            RoundedRectangle(cornerRadius: 0.5)
              .fill(Color.diffAddedEdge)
              .frame(
                width: microBarWidth(count: file.stats.additions, total: file.stats.additions + file.stats.deletions),
                height: 3
              )
          }
          if file.stats.deletions > 0 {
            RoundedRectangle(cornerRadius: 0.5)
              .fill(Color.diffRemovedEdge)
              .frame(
                width: microBarWidth(count: file.stats.deletions, total: file.stats.additions + file.stats.deletions),
                height: 3
              )
          }
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(isSelected ? Color.accent.opacity(OpacityTier.light) : Color.backgroundTertiary.opacity(0.5))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .strokeBorder(isSelected ? Color.accent.opacity(OpacityTier.medium) : Color.clear, lineWidth: 1)
    )
  }

  private func microBarWidth(count: Int, total: Int) -> CGFloat {
    guard total > 0 else { return 0 }
    return max(3, CGFloat(count) / CGFloat(total) * 16)
  }

  private func chipColor(_ type: FileChangeType) -> Color {
    switch type {
      case .added: Color.diffAddedAccent
      case .deleted: Color.diffRemovedAccent
      case .renamed, .modified: Color.accent
    }
  }

  private func compactSourceButton(
    label: String,
    icon: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Spacing.gap) {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .medium))
        Text(label)
          .font(.system(size: TypeScale.micro, weight: isSelected ? .semibold : .medium))
      }
      .foregroundStyle(isSelected ? Color.accent : .secondary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.gap)
      .background(
        isSelected ? Color.accent.opacity(OpacityTier.light) : Color.backgroundTertiary.opacity(0.5),
        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .strokeBorder(isSelected ? Color.accent.opacity(OpacityTier.medium) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

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

  private func changeTypeColor(_ type: FileChangeType) -> Color {
    switch type {
      case .added: Color.diffAddedAccent
      case .deleted: Color.diffRemovedAccent
      case .renamed, .modified: Color.accent
    }
  }

  private func fileIcon(_ type: FileChangeType) -> String {
    switch type {
      case .added: "plus"
      case .deleted: "minus"
      case .renamed: "arrow.right"
      case .modified: "pencil"
    }
  }

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
