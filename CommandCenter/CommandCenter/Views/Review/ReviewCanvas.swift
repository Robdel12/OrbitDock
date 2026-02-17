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

// MARK: - Cursor Target

/// Identifies a single navigable element in the unified diff view.
private enum CursorTarget: Equatable, Hashable {
  case fileHeader(fileIndex: Int)
  case hunkHeader(fileIndex: Int, hunkIndex: Int)
  case diffLine(fileIndex: Int, hunkIndex: Int, lineIndex: Int)

  var fileIndex: Int {
    switch self {
      case let .fileHeader(f): f
      case let .hunkHeader(f, _): f
      case let .diffLine(f, _, _): f
    }
  }

  var scrollId: String {
    switch self {
      case let .fileHeader(f): "file-\(f)"
      case let .hunkHeader(f, h): "file-\(f)-hunk-\(h)"
      case let .diffLine(f, h, l): "file-\(f)-hunk-\(h)-line-\(l)"
    }
  }

  var isFileHeader: Bool {
    if case .fileHeader = self { return true }
    return false
  }

  var isHunkHeader: Bool {
    if case .hunkHeader = self { return true }
    return false
  }
}

// MARK: - Composer Line Range

private struct ComposerLineRange: Equatable {
  let filePath: String
  let fileIndex: Int
  let hunkIndex: Int
  let lineStartIdx: Int // Index in hunk.lines
  let lineEndIdx: Int
  let lineStart: UInt32 // Actual new-side line number for server
  let lineEnd: UInt32?
}

// MARK: - Review Round Tracking

/// Records the state when a batch of review comments was sent to the model.
/// Used to detect which files the model modified in response to review feedback.
private struct ReviewRound {
  let sentAt: Date
  let turnDiffCountAtSend: Int // obs.turnDiffs.count when review was sent
  let reviewedFilePaths: Set<String>
  let commentCount: Int
}

// MARK: - Diff Parse Cache

/// Memoizes DiffModel.parse() to avoid re-parsing the same diff string on every body evaluation.
/// Stored as @State so it persists across body re-evaluations.
private final class DiffParseCache {
  private var lastRaw: String?
  private var lastModel: DiffModel?

  func model(for raw: String?) -> DiffModel? {
    if raw == lastRaw { return lastModel }
    lastRaw = raw
    if let r = raw, !r.isEmpty {
      lastModel = DiffModel.parse(unifiedDiff: r)
    } else {
      lastModel = nil
    }
    return lastModel
  }
}

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

  @Environment(ServerAppState.self) private var serverState

  @State private var cursorIndex: Int = 0
  @State private var collapsedFiles: Set<String> = []
  @State private var collapsedHunks: Set<String> = []
  @State private var expandedContextBars: Set<String> = []
  @State private var selectedTurnDiffId: String?
  @State private var isFollowing = true
  @State private var previousFileCount = 0
  @FocusState private var isCanvasFocused: Bool

  // Comment state
  @State private var commentMark: CursorTarget?
  @State private var composerTarget: ComposerLineRange?
  @State private var composerBody: String = ""
  @State private var composerTag: ServerReviewCommentTag? = nil

  // Mouse drag state for gutter range selection
  @State private var mouseDragAnchor: (fileIdx: Int, hunkIdx: Int, lineIdx: Int)?
  @State private var mouseDragCurrent: (fileIdx: Int, hunkIdx: Int, lineIdx: Int)?

  // Review round tracking — detects which files the model modified after feedback
  @State private var lastReviewRound: ReviewRound?
  @State private var showReviewBanner: Bool = true
  @State private var showResolvedComments: Bool = false

  /// Diff parsing cache — avoids re-parsing on every body evaluation
  @State private var diffParseCache = DiffParseCache()

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

  // MARK: - Cursor Helpers

  /// Build flat ordered list of all visible cursor targets (respecting collapsed files).
  private func computeVisibleTargets(_ model: DiffModel) -> [CursorTarget] {
    var targets: [CursorTarget] = []
    for (fileIdx, file) in model.files.enumerated() {
      targets.append(.fileHeader(fileIndex: fileIdx))
      guard !collapsedFiles.contains(file.id) else { continue }
      for (hunkIdx, hunk) in file.hunks.enumerated() {
        targets.append(.hunkHeader(fileIndex: fileIdx, hunkIndex: hunkIdx))
        let hunkKey = "\(fileIdx)-\(hunkIdx)"
        guard !collapsedHunks.contains(hunkKey) else { continue }
        for lineIdx in 0 ..< hunk.lines.count {
          targets.append(.diffLine(fileIndex: fileIdx, hunkIndex: hunkIdx, lineIndex: lineIdx))
        }
      }
    }
    return targets
  }

  /// Resolve the current cursor target from cursorIndex.
  private func currentTarget(_ model: DiffModel) -> CursorTarget? {
    let targets = computeVisibleTargets(model)
    guard !targets.isEmpty else { return nil }
    let idx = min(cursorIndex, targets.count - 1)
    return targets[idx]
  }

  /// File index at the cursor position.
  private func currentFileIndex(_ model: DiffModel) -> Int {
    currentTarget(model)?.fileIndex ?? 0
  }

  /// The FileDiff at cursor position.
  private func currentFile(_ model: DiffModel) -> FileDiff? {
    let idx = currentFileIndex(model)
    return idx < model.files.count ? model.files[idx] : nil
  }

  /// Check if cursor is on a specific hunk header.
  private func isCursorOnHunkHeader(fileIdx: Int, hunkIdx: Int, target: CursorTarget?) -> Bool {
    target == .hunkHeader(fileIndex: fileIdx, hunkIndex: hunkIdx)
  }

  /// Get the cursor line index within a specific hunk (nil if cursor not in this hunk).
  private func cursorLineForHunk(fileIdx: Int, hunkIdx: Int, target: CursorTarget?) -> Int? {
    guard case let .diffLine(f, h, l) = target, f == fileIdx, h == hunkIdx else { return nil }
    return l
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
      let targets = computeVisibleTargets(model)
      let newFileCount = model.files.count

      // Clamp cursor
      if targets.isEmpty {
        cursorIndex = 0
      } else if cursorIndex >= targets.count {
        cursorIndex = targets.count - 1
      }

      // Auto-follow: new file appeared, jump to its header
      if isFollowing, isSessionActive, newFileCount > previousFileCount {
        if let lastFileIdx = targets.lastIndex(where: { $0.isFileHeader }) {
          cursorIndex = lastFileIdx
        }
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
        commentCounts: buildCommentCounts(),
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

    return HStack(spacing: 8) {
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
          withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
            showResolvedComments.toggle()
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: showResolvedComments ? "eye.fill" : "eye.slash")
              .font(.system(size: TypeScale.micro, weight: .medium))
            Text("History")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(showResolvedComments ? Color.statusQuestion : Color.white.opacity(0.3))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
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
          if isFollowing {
            let targets = computeVisibleTargets(model)
            if let lastFile = targets.lastIndex(where: { $0.isFileHeader }) {
              cursorIndex = lastFile
            }
          }
        } label: {
          HStack(spacing: 4) {
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
      HStack(spacing: 4) {
        Text("+\(totalAdds)")
          .foregroundStyle(Color.diffAddedAccent.opacity(0.8))
        Text("\u{2212}\(totalDels)")
          .foregroundStyle(Color.diffRemovedAccent.opacity(0.8))
      }
      .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, 6)
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
    let targets = computeVisibleTargets(model)
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
                  cursorLineIndex: cursorLineForHunk(fileIdx: fileIdx, hunkIdx: hunkIdx, target: target),
                  isCursorOnHeader: isCursorOnHunkHeader(fileIdx: fileIdx, hunkIdx: hunkIdx, target: target),
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
                  if let ct = composerTarget,
                     ct.fileIndex == fileIdx,
                     ct.hunkIndex == hunkIdx,
                     ct.lineEndIdx == lineIdx
                  {
                    let fileName = ct.filePath.components(separatedBy: "/").last ?? ct.filePath
                    let lineLabel = ct.lineEnd.map { end in
                      end != ct.lineStart ? "Lines \(ct.lineStart)–\(end)" : "Line \(ct.lineStart)"
                    } ?? "Line \(ct.lineStart)"

                    CommentComposerView(
                      commentBody: $composerBody,
                      tag: $composerTag,
                      fileName: fileName,
                      lineLabel: lineLabel,
                      onSubmit: { submitComment() },
                      onCancel: { composerTarget = nil; composerBody = ""; composerTag = nil }
                    )
                    .id("composer-\(fileIdx)-\(hunkIdx)-\(lineIdx)")
                  }
                }
              }
            }
          }

          Color.clear.frame(height: 32)
        }
      }
      .onChange(of: cursorIndex) { _, newIdx in
        let currentTargets = computeVisibleTargets(model)
        guard !currentTargets.isEmpty else { return }
        let safe = min(newIdx, currentTargets.count - 1)
        withAnimation(.spring(response: 0.15, dampingFraction: 0.9)) {
          proxy.scrollTo(currentTargets[safe].scrollId, anchor: .center)
        }
      }
    }
    .focusable()
    .focused($isCanvasFocused)
    .onKeyPress(keys: [.escape]) { _ in
      // Clear mark first, then composer — always consume to prevent closing review
      if commentMark != nil {
        commentMark = nil
      } else if composerTarget != nil {
        composerTarget = nil
        composerBody = ""
        composerTag = nil
      }
      // Always handled: q is the close key, not Escape
      return .handled
    }
    .onKeyPress(keys: [.tab]) { _ in
      guard composerTarget == nil else { return .ignored }
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
      guard composerTarget == nil else { return .ignored }
      guard let model = diffModel, let file = currentFile(model) else { return .ignored }
      openFileInEditor(file)
      return .handled
    }
    .onKeyPress { keyPress in
      guard composerTarget == nil else { return .ignored }
      guard let model = diffModel else { return .ignored }
      return handleKeyPress(keyPress, model: model)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      if hasOpenComments {
        sendReviewBar
      }
    }
  }

  private var sendReviewBar: some View {
    let openCount = obs.reviewComments.filter { $0.status == .open && commentMatchesTurnView($0) }.count
    let selectedCount = selectedCommentIds.count
    let hasSelection = selectedCount > 0
    let sendCount = hasSelection ? selectedCount : openCount
    let label = hasSelection
      ? "Send \(sendCount) selected"
      : "Send \(sendCount) comment\(sendCount == 1 ? "" : "s") to model"

    return HStack(spacing: 8) {
      // Clear selection button (only when selection active)
      if hasSelection {
        Button {
          selectedCommentIds.removeAll()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "xmark")
              .font(.system(size: TypeScale.micro, weight: .bold))
            Text("\(selectedCount) selected")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(.white.opacity(0.7))
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .background(.white.opacity(OpacityTier.light), in: Capsule())
        }
        .buttonStyle(.plain)
      }

      Button(action: sendReview) {
        HStack(spacing: 8) {
          Image(systemName: "paperplane.fill")
            .font(.system(size: TypeScale.body, weight: .medium))

          Text(label)
            .font(.system(size: TypeScale.code, weight: .semibold))

          Text("S")
            .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.white.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.statusQuestion, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
      }
      .buttonStyle(.plain)
    }
    .padding(.bottom, 16)
    .transition(.move(edge: .bottom).combined(with: .opacity))
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sendCount)
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
        .frame(width: 24)

      // Change type icon
      ZStack {
        Circle()
          .fill(changeTypeColor(file.changeType).opacity(OpacityTier.light))
          .frame(width: 22, height: 22)
        Image(systemName: fileIcon(file.changeType))
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(changeTypeColor(file.changeType))
      }
      .padding(.trailing, 8)

      // File path — dir dimmed, filename bold
      filePathLabel(file.newPath)
        .padding(.trailing, 8)

      // Stats badge
      HStack(spacing: 6) {
        if file.stats.additions > 0 {
          HStack(spacing: 2) {
            Text("+")
              .foregroundStyle(Color.diffAddedAccent.opacity(0.7))
            Text("\(file.stats.additions)")
              .foregroundStyle(Color.diffAddedAccent)
          }
        }
        if file.stats.deletions > 0 {
          HStack(spacing: 2) {
            Text("\u{2212}")
              .foregroundStyle(Color.diffRemovedAccent.opacity(0.7))
            Text("\(file.stats.deletions)")
              .foregroundStyle(Color.diffRemovedAccent)
          }
        }
      }
      .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))

      // Review status badge
      if let addressed = isFileAddressed(file.newPath) {
        HStack(spacing: 3) {
          Image(systemName: addressed ? "checkmark" : "clock")
            .font(.system(size: 8, weight: .bold))
          Text(addressed ? "Updated" : "In review")
            .font(.system(size: TypeScale.micro, weight: .semibold))
        }
        .foregroundStyle(addressed ? Color.accent : Color.statusQuestion)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          (addressed ? Color.accent : Color.statusQuestion).opacity(OpacityTier.light),
          in: Capsule()
        )
      }

      Spacer(minLength: 16)

      // Collapsed hunk count hint
      if isCollapsed {
        Text("\(file.hunks.count) hunk\(file.hunks.count == 1 ? "" : "s")")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(.tertiary)
          .padding(.trailing, 8)
      }
    }
    .padding(.vertical, 8)
    .padding(.trailing, 8)
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
          .foregroundStyle(.tertiary)
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
      if commentMark != nil {
        commentMark = nil
      } else if composerTarget != nil {
        composerTarget = nil
        composerBody = ""
        composerTag = nil
      }
      return .handled
    }
    // C-space — set mark for range selection
    if keyPress.key == " ", keyPress.modifiers.contains(.control) {
      let target = currentTarget(model)
      if case .diffLine = target, let t = target, diffLineHasNewLineNum(t, model: model) {
        commentMark = t
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
          let targets = computeVisibleTargets(model)
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
    let targets = computeVisibleTargets(model)
    guard !targets.isEmpty else { return }
    isFollowing = false
    cursorIndex = max(0, min(cursorIndex + delta, targets.count - 1))
  }

  /// Jump cursor to next/prev section header — file headers + hunk headers.
  private func jumpToNextHunk(forward: Bool, in model: DiffModel) {
    let targets = computeVisibleTargets(model)
    guard !targets.isEmpty else { return }
    isFollowing = false
    let safeIdx = min(cursorIndex, targets.count - 1)

    if forward {
      for i in (safeIdx + 1) ..< targets.count {
        if targets[i].isHunkHeader || targets[i].isFileHeader {
          cursorIndex = i
          return
        }
      }
    } else {
      // If not on a section header, jump to current hunk's header first
      let onHeader = targets[safeIdx].isHunkHeader || targets[safeIdx].isFileHeader
      if !onHeader {
        for i in stride(from: safeIdx, through: 0, by: -1) {
          if targets[i].isHunkHeader || targets[i].isFileHeader {
            cursorIndex = i
            return
          }
        }
      } else {
        for i in stride(from: safeIdx - 1, through: 0, by: -1) {
          if targets[i].isHunkHeader || targets[i].isFileHeader {
            cursorIndex = i
            return
          }
        }
      }
    }
  }

  // MARK: - Collapse

  /// Toggle collapse of the file at the given file index, repositioning cursor to the file header.
  private func toggleCollapseAtCursor(model: DiffModel, fileIdx: Int) {
    guard fileIdx < model.files.count else { return }
    let fileId = model.files[fileIdx].id

    withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
      if collapsedFiles.contains(fileId) {
        collapsedFiles.remove(fileId)
      } else {
        collapsedFiles.insert(fileId)
      }
    }

    // Snap cursor to the file header after toggle
    let newTargets = computeVisibleTargets(model)
    if let idx = newTargets.firstIndex(of: .fileHeader(fileIndex: fileIdx)) {
      cursorIndex = idx
    } else if !newTargets.isEmpty {
      cursorIndex = min(cursorIndex, newTargets.count - 1)
    }
  }

  /// Toggle collapse of a specific hunk, repositioning cursor to the hunk header.
  private func toggleHunkCollapse(model: DiffModel, fileIdx: Int, hunkIdx: Int) {
    let hunkKey = "\(fileIdx)-\(hunkIdx)"

    withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
      if collapsedHunks.contains(hunkKey) {
        collapsedHunks.remove(hunkKey)
      } else {
        collapsedHunks.insert(hunkKey)
      }
    }

    // Snap cursor to the hunk header after toggle
    let newTargets = computeVisibleTargets(model)
    if let idx = newTargets.firstIndex(of: .hunkHeader(fileIndex: fileIdx, hunkIndex: hunkIdx)) {
      cursorIndex = idx
    } else if !newTargets.isEmpty {
      cursorIndex = min(cursorIndex, newTargets.count - 1)
    }
  }

  // MARK: - Comment Helpers

  /// Get all comments whose range ends at this line (so thread appears after the last selected line).
  /// Scoped to the active turn view — when viewing a specific turn, only shows that turn's comments.
  private func commentsForLine(filePath: String, lineNum: Int) -> [ServerReviewComment] {
    obs.reviewComments.filter { comment in
      comment.filePath == filePath &&
        Int(comment.lineEnd ?? comment.lineStart) == lineNum &&
        commentMatchesTurnView(comment)
    }
  }

  /// Group resolved comments by proximity — adjacent lineEnd values merge into a single marker.
  /// Returns a map of newLineNum → [comments] where the key is the last line in each contiguous group.
  private func groupedResolvedComments(forFile filePath: String) -> [Int: [ServerReviewComment]] {
    let resolved = obs.reviewComments.filter { comment in
      comment.filePath == filePath &&
        comment.status == .resolved &&
        commentMatchesTurnView(comment)
    }

    guard !resolved.isEmpty else { return [:] }

    // Group by lineEnd
    var byLineEnd: [Int: [ServerReviewComment]] = [:]
    for comment in resolved {
      let lineEnd = Int(comment.lineEnd ?? comment.lineStart)
      byLineEnd[lineEnd, default: []].append(comment)
    }

    // Sort and merge adjacent groups
    let sortedLines = byLineEnd.keys.sorted()
    var merged: [Int: [ServerReviewComment]] = [:]
    var currentGroup: [ServerReviewComment] = []
    var currentEnd: Int = -10

    for lineNum in sortedLines {
      if lineNum <= currentEnd + 1 {
        // Adjacent — merge into current group
        currentGroup.append(contentsOf: byLineEnd[lineNum]!)
        currentEnd = lineNum
      } else {
        // Gap — flush previous group
        if !currentGroup.isEmpty {
          merged[currentEnd] = currentGroup
        }
        currentGroup = byLineEnd[lineNum]!
        currentEnd = lineNum
      }
    }
    if !currentGroup.isEmpty {
      merged[currentEnd] = currentGroup
    }

    return merged
  }

  /// Build a map of filePath → open comment count for the file list.
  private func buildCommentCounts() -> [String: Int] {
    var counts: [String: Int] = [:]
    for comment in obs.reviewComments where comment.status == .open && commentMatchesTurnView(comment) {
      counts[comment.filePath, default: 0] += 1
    }
    return counts
  }

  /// Set of new-side line numbers that have comments for a given file.
  /// In normal mode, only marks open comments. In history mode, marks all.
  private func commentedNewLineNums(forFile filePath: String) -> Set<Int> {
    var result = Set<Int>()
    for comment in obs.reviewComments where comment.filePath == filePath && commentMatchesTurnView(comment) {
      if !showResolvedComments, comment.status != .open { continue }
      let start = Int(comment.lineStart)
      let end = Int(comment.lineEnd ?? comment.lineStart)
      for line in start ... end {
        result.insert(line)
      }
    }
    return result
  }

  /// Whether a comment matches the currently active turn view.
  /// "All Changes" view shows all comments; per-turn view shows only that turn's comments
  /// (plus comments with no turn, which are global).
  private func commentMatchesTurnView(_ comment: ServerReviewComment) -> Bool {
    guard let activeTurn = selectedTurnDiffId else { return true } // "All Changes" shows everything
    return comment.turnId == nil || comment.turnId == activeTurn
  }

  /// Set of line indices within a hunk that fall in the mark-to-cursor selection range.
  private func selectionLineIndices(fileIdx: Int, hunkIdx: Int) -> Set<Int> {
    guard let mark = commentMark else { return [] }
    guard let model = diffModel else { return [] }
    guard case let .diffLine(mf, mh, ml) = mark else { return [] }
    guard let target = currentTarget(model) else { return [] }
    guard case let .diffLine(cf, ch, cl) = target else { return [] }

    // Only highlight when both mark and cursor are in the same file
    guard mf == cf, mf == fileIdx else { return [] }

    // Build range across hunks
    let startHunk = min(mh, ch)
    let endHunk = max(mh, ch)

    guard hunkIdx >= startHunk, hunkIdx <= endHunk else { return [] }

    let startLine = mh < ch ? ml : (mh == ch ? min(ml, cl) : cl)
    let endLine = mh < ch ? cl : (mh == ch ? max(ml, cl) : ml)

    if startHunk == endHunk {
      // Same hunk
      guard hunkIdx == startHunk else { return [] }
      return Set(min(startLine, endLine) ... max(startLine, endLine))
    }

    // Cross-hunk selection
    if hunkIdx == startHunk {
      let hunkLineCount = model.files[fileIdx].hunks[hunkIdx].lines.count
      let sl = mh < ch ? ml : cl
      return Set(sl ..< hunkLineCount)
    } else if hunkIdx == endHunk {
      let el = mh < ch ? cl : ml
      return Set(0 ... el)
    } else {
      // Entire hunk is in selection
      let hunkLineCount = model.files[fileIdx].hunks[hunkIdx].lines.count
      return Set(0 ..< hunkLineCount)
    }
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
    let file = model.files[fileIdx]
    let hunk = file.hunks[hunkIdx]

    // Clear any keyboard mark
    commentMark = nil

    // Use the smart range to find start/end new-side line numbers
    let startIdx = smartRange.lowerBound
    let endIdx = smartRange.upperBound

    // Find first new-side line number in range (skip removed-only lines)
    var startNewLine: Int?
    for i in startIdx ... endIdx {
      if let n = hunk.lines[i].newLineNum { startNewLine = n; break }
    }

    // Find last new-side line number in range
    var endNewLine: Int?
    for i in stride(from: endIdx, through: startIdx, by: -1) {
      if let n = hunk.lines[i].newLineNum { endNewLine = n; break }
    }

    guard let sn = startNewLine else { return }

    composerTarget = ComposerLineRange(
      filePath: file.newPath,
      fileIndex: fileIdx,
      hunkIndex: hunkIdx,
      lineStartIdx: startIdx,
      lineEndIdx: endIdx,
      lineStart: UInt32(sn),
      lineEnd: endNewLine.map { UInt32($0) }
    )
    composerBody = ""
    composerTag = nil
  }

  /// Handle drag update — show selection highlight.
  private func handleLineDragChanged(fileIdx: Int, hunkIdx: Int, anchor: Int, current: Int) {
    commentMark = nil
    mouseDragAnchor = (fileIdx, hunkIdx, anchor)
    mouseDragCurrent = (fileIdx, hunkIdx, current)
  }

  /// Handle drag end — open composer for the dragged range.
  private func handleLineDragEnded(fileIdx: Int, hunkIdx: Int, startIdx: Int, endIdx: Int, model: DiffModel) {
    let file = model.files[fileIdx]
    let hunk = file.hunks[hunkIdx]

    // Find new-side line numbers for the range
    var startNewLine: Int?
    for i in startIdx ... endIdx {
      if let n = hunk.lines[i].newLineNum { startNewLine = n; break }
    }
    var endNewLine: Int?
    for i in stride(from: endIdx, through: startIdx, by: -1) {
      if let n = hunk.lines[i].newLineNum { endNewLine = n; break }
    }

    guard let sn = startNewLine else {
      mouseDragAnchor = nil
      mouseDragCurrent = nil
      return
    }

    composerTarget = ComposerLineRange(
      filePath: file.newPath,
      fileIndex: fileIdx,
      hunkIndex: hunkIdx,
      lineStartIdx: startIdx,
      lineEndIdx: endIdx,
      lineStart: UInt32(sn),
      lineEnd: endNewLine.map { UInt32($0) }
    )
    composerBody = ""
    composerTag = nil

    mouseDragAnchor = nil
    mouseDragCurrent = nil
  }

  /// Line index range within a hunk that has an active composer open.
  private func composerLineRangeForHunk(fileIdx: Int, hunkIdx: Int) -> ClosedRange<Int>? {
    guard let ct = composerTarget,
          ct.fileIndex == fileIdx,
          ct.hunkIndex == hunkIdx else { return nil }
    return ct.lineStartIdx ... ct.lineEndIdx
  }

  /// Line indices within a hunk that fall in the mouse drag selection.
  private func mouseSelectionLineIndices(fileIdx: Int, hunkIdx: Int) -> Set<Int> {
    guard let anchor = mouseDragAnchor, let current = mouseDragCurrent else { return [] }
    guard anchor.fileIdx == fileIdx, anchor.hunkIdx == hunkIdx,
          current.fileIdx == fileIdx, current.hunkIdx == hunkIdx else { return [] }

    let start = min(anchor.lineIdx, current.lineIdx)
    let end = max(anchor.lineIdx, current.lineIdx)
    return Set(start ... end)
  }

  /// Check if a cursor target (diffLine) has a non-nil newLineNum.
  private func diffLineHasNewLineNum(_ target: CursorTarget, model: DiffModel) -> Bool {
    guard case let .diffLine(f, h, l) = target else { return false }
    guard f < model.files.count else { return false }
    let file = model.files[f]
    guard h < file.hunks.count else { return false }
    let hunk = file.hunks[h]
    guard l < hunk.lines.count else { return false }
    return hunk.lines[l].newLineNum != nil
  }

  /// Open the comment composer for the current cursor position or mark range.
  private func openComposer(model: DiffModel) -> KeyPress.Result {
    let target = currentTarget(model)

    if let mark = commentMark {
      // Range comment: mark to cursor
      guard case let .diffLine(mf, mh, ml) = mark,
            case let .diffLine(cf, ch, cl) = target,
            mf == cf
      else {
        commentMark = nil
        return .handled
      }

      let file = model.files[mf]
      let startHunk = min(mh, ch)
      let endHunk = max(mh, ch)
      let startLine = startHunk == endHunk ? min(ml, cl) : (mh <= ch ? ml : cl)
      let endLine = startHunk == endHunk ? max(ml, cl) : (mh <= ch ? cl : ml)

      let startNewLine = file.hunks[startHunk].lines[startLine].newLineNum
      let endNewLine = file.hunks[endHunk].lines[endLine].newLineNum

      guard let sn = startNewLine else {
        commentMark = nil
        return .handled
      }

      composerTarget = ComposerLineRange(
        filePath: file.newPath,
        fileIndex: mf,
        hunkIndex: endHunk,
        lineStartIdx: startLine,
        lineEndIdx: endLine,
        lineStart: UInt32(sn),
        lineEnd: endNewLine.map { UInt32($0) }
      )
      composerBody = ""
      composerTag = nil
      commentMark = nil
      return .handled
    }

    // Single-line comment
    guard case let .diffLine(f, h, l) = target else { return .ignored }
    let file = model.files[f]
    let line = file.hunks[h].lines[l]
    guard let newLine = line.newLineNum else { return .ignored }

    composerTarget = ComposerLineRange(
      filePath: file.newPath,
      fileIndex: f,
      hunkIndex: h,
      lineStartIdx: l,
      lineEndIdx: l,
      lineStart: UInt32(newLine),
      lineEnd: nil
    )
    composerBody = ""
    composerTag = nil
    return .handled
  }

  /// Submit the current comment to the server.
  /// Associates the comment with the correct turn diff — either the one being viewed,
  /// or auto-inferred from the file when on "All Changes" view.
  private func submitComment() {
    guard let ct = composerTarget else { return }
    let trimmed = composerBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Smart turn association: if viewing "All Changes", find the latest turn that
    // modified this file so the comment shows up on the correct edit turn.
    let turnId = selectedTurnDiffId ?? inferTurnId(forFile: ct.filePath)

    serverState.createReviewComment(
      sessionId: sessionId,
      turnId: turnId,
      filePath: ct.filePath,
      lineStart: ct.lineStart,
      lineEnd: ct.lineEnd,
      body: trimmed,
      tag: composerTag
    )

    composerTarget = nil
    composerBody = ""
    composerTag = nil
  }

  /// Resolve/unresolve a comment.
  private func resolveComment(_ comment: ServerReviewComment) {
    let newStatus: ServerReviewCommentStatus = comment.status == .open ? .resolved : .open
    serverState.updateReviewComment(
      commentId: comment.id,
      body: nil,
      tag: nil,
      status: newStatus
    )
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
    let targets = computeVisibleTargets(model)
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
          _ = withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
            collapsedFiles.remove(fileId)
          }
        }
        let hunkKey = "\(f)-\(h)"
        if collapsedHunks.contains(hunkKey) {
          _ = withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
            collapsedHunks.remove(hunkKey)
          }
        }

        // Recompute targets after expansion and find the right index
        let newTargets = computeVisibleTargets(model)
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
  private func buildUnresolvedCommentLineMap(model: DiffModel) -> [String: Set<Int>] {
    var map: [String: Set<Int>] = [:]
    for comment in obs.reviewComments where comment.status == .open && commentMatchesTurnView(comment) {
      map[comment.filePath, default: []].insert(Int(comment.lineStart))
    }
    return map
  }

  // MARK: - Navigate to Comment

  private func handleNavigateToComment(_ model: DiffModel) {
    guard let comment = navigateToComment?.wrappedValue else { return }

    // Find the file
    guard let fileIdx = model.files.firstIndex(where: { $0.newPath == comment.filePath }) else { return }
    let file = model.files[fileIdx]

    // Expand file if collapsed
    if collapsedFiles.contains(file.id) {
      _ = withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
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
            _ = withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
              collapsedHunks.remove(hunkKey)
            }
          }

          // Move cursor
          let targets = computeVisibleTargets(model)
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

  /// Format all open comments into a structured review message the model can act on.
  /// Includes actual diff content so the model sees exactly what's being commented on.
  private func formatReviewMessage(comments commentsToSend: [ServerReviewComment]) -> String? {
    guard !commentsToSend.isEmpty else { return nil }

    let model = diffModel

    // Group by file path, preserving order of first appearance
    var fileOrder: [String] = []
    var grouped: [String: [ServerReviewComment]] = [:]
    for comment in commentsToSend {
      if grouped[comment.filePath] == nil {
        fileOrder.append(comment.filePath)
      }
      grouped[comment.filePath, default: []].append(comment)
    }

    var lines: [String] = ["## Code Review Feedback", ""]

    for filePath in fileOrder {
      let comments = grouped[filePath] ?? []
      let ext = filePath.components(separatedBy: ".").last ?? ""
      lines.append("### \(filePath)")

      for comment in comments.sorted(by: { $0.lineStart < $1.lineStart }) {
        let lineRef = if let end = comment.lineEnd, end != comment.lineStart {
          "Lines \(comment.lineStart)–\(end)"
        } else {
          "Line \(comment.lineStart)"
        }

        let tagStr = comment.tag.map { " [\($0.rawValue)]" } ?? ""
        lines.append("")
        lines.append("**\(lineRef)**\(tagStr):")

        // Include actual diff content for this line range
        if let diffContent = extractDiffLines(
          model: model,
          filePath: filePath,
          lineStart: Int(comment.lineStart),
          lineEnd: comment.lineEnd.map { Int($0) }
        ) {
          lines.append("```\(ext)")
          lines.append(diffContent)
          lines.append("```")
        }

        lines.append("> \(comment.body)")
      }

      lines.append("")
    }

    // Embed comment IDs as HTML comment for transcript traceability
    // Invisible to the model but parseable from stored messages
    let ids = commentsToSend.map(\.id).joined(separator: ",")
    lines.append("<!-- review-comment-ids: \(ids) -->")

    return lines.joined(separator: "\n")
  }

  /// Extract actual diff lines for a comment's file + line range from the parsed diff model.
  private func extractDiffLines(model: DiffModel?, filePath: String, lineStart: Int, lineEnd: Int?) -> String? {
    guard let model else { return nil }
    guard let file = model.files.first(where: { $0.newPath == filePath }) else { return nil }

    let end = lineEnd ?? lineStart
    var extracted: [String] = []

    for hunk in file.hunks {
      for line in hunk.lines {
        guard let newNum = line.newLineNum else {
          // Removed lines adjacent to the range — include for context
          if !extracted.isEmpty, line.type == .removed {
            extracted.append("\(line.prefix)\(line.content)")
          }
          continue
        }
        if newNum >= lineStart, newNum <= end {
          extracted.append("\(line.prefix)\(line.content)")
        }
      }
    }

    return extracted.isEmpty ? nil : extracted.joined(separator: "\n")
  }

  /// Send review comments as structured feedback to the model, then resolve them.
  /// If comments are selected (via `x`), sends only those. Otherwise sends all open.
  /// Records a review round to track which files the model modifies in response.
  private func sendReview() {
    let openComments = obs.reviewComments.filter { $0.status == .open }
    guard !openComments.isEmpty else { return }

    // Use selected comments if any, otherwise all open
    let commentsToSend: [ServerReviewComment]
    if !selectedCommentIds.isEmpty {
      commentsToSend = openComments.filter { selectedCommentIds.contains($0.id) }
      guard !commentsToSend.isEmpty else { return }
    } else {
      commentsToSend = openComments
    }

    guard let message = formatReviewMessage(comments: commentsToSend) else { return }

    // Record review round before sending
    let reviewedFiles = Set(commentsToSend.map(\.filePath))
    lastReviewRound = ReviewRound(
      sentAt: Date(),
      turnDiffCountAtSend: obs.turnDiffs.count,
      reviewedFilePaths: reviewedFiles,
      commentCount: commentsToSend.count
    )
    showReviewBanner = true

    serverState.sendMessage(sessionId: sessionId, content: message)

    // Mark sent comments as resolved
    for comment in commentsToSend {
      serverState.updateReviewComment(
        commentId: comment.id,
        body: nil,
        tag: nil,
        status: .resolved
      )
    }

    // Clear selection after send
    selectedCommentIds.removeAll()
  }

  private var hasOpenComments: Bool {
    obs.reviewComments.contains { $0.status == .open && commentMatchesTurnView($0) }
  }

  private var hasResolvedComments: Bool {
    obs.reviewComments.contains { $0.status == .resolved && commentMatchesTurnView($0) }
  }

  // MARK: - Review Banner

  @ViewBuilder
  private var reviewBanner: some View {
    if let round = lastReviewRound, showReviewBanner {
      let addressed = addressedFilePaths
      let hasChanges = hasPostReviewChanges
      let accentColor = hasChanges ? Color.accent : Color.statusQuestion

      HStack(spacing: 0) {
        // Left accent bar
        Rectangle()
          .fill(accentColor)
          .frame(width: 3)

        HStack(spacing: Spacing.sm) {
          // Status icon
          if hasChanges {
            Image(systemName: addressed.count == round.reviewedFilePaths.count
              ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(accentColor)
          } else {
            Image(systemName: "paperplane.fill")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(accentColor)
          }

          // Status text
          if hasChanges {
            let total = round.reviewedFilePaths.count
            Text("\(addressed.count) of \(total) reviewed file\(total == 1 ? "" : "s") updated")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(.primary.opacity(OpacityTier.vivid))
          } else {
            Text("Review sent")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(.primary.opacity(OpacityTier.vivid))

            Text(
              "\(round.commentCount) comment\(round.commentCount == 1 ? "" : "s") on \(round.reviewedFilePaths.count) file\(round.reviewedFilePaths.count == 1 ? "" : "s")"
            )
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(.tertiary)
          }

          Spacer()

          // Dismiss button
          Button {
            withAnimation(.easeOut(duration: 0.15)) {
              showReviewBanner = false
            }
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.quaternary)
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
  private func isFileAddressed(_ filePath: String) -> Bool? {
    guard let round = lastReviewRound else { return nil }
    guard round.reviewedFilePaths.contains(filePath) else { return nil }

    // Check turn diffs that arrived AFTER the review was sent
    let postReviewDiffs = Array(obs.turnDiffs.dropFirst(round.turnDiffCountAtSend))
    if postReviewDiffs.isEmpty { return false } // Model hasn't produced changes yet

    for td in postReviewDiffs {
      if diffMentionsFile(td.diff, filePath: filePath) { return true }
    }
    return false
  }

  /// Set of file paths that were part of the last review round.
  private var reviewedFilePaths: Set<String> {
    lastReviewRound?.reviewedFilePaths ?? []
  }

  /// Set of file paths the model modified after the last review.
  private var addressedFilePaths: Set<String> {
    guard let round = lastReviewRound else { return [] }
    let postReviewDiffs = Array(obs.turnDiffs.dropFirst(round.turnDiffCountAtSend))
    guard !postReviewDiffs.isEmpty else { return [] }

    var addressed = Set<String>()
    for td in postReviewDiffs {
      for path in round.reviewedFilePaths {
        if diffMentionsFile(td.diff, filePath: path) {
          addressed.insert(path)
        }
      }
    }
    return addressed
  }

  /// Whether the model has produced any new turn diffs since the last review.
  private var hasPostReviewChanges: Bool {
    guard let round = lastReviewRound else { return false }
    return obs.turnDiffs.count > round.turnDiffCountAtSend
  }

  /// Quick check if a unified diff string contains changes for a specific file.
  private func diffMentionsFile(_ diff: String, filePath: String) -> Bool {
    diff.contains("+++ b/\(filePath)") || diff.contains("--- a/\(filePath)")
  }

  /// Infer which turn a comment belongs to by finding the latest turn that touched the file.
  /// Used when commenting on "All Changes" — maps the comment to the right edit turn.
  private func inferTurnId(forFile filePath: String) -> String? {
    for turnDiff in obs.turnDiffs.reversed() {
      if diffMentionsFile(turnDiff.diff, filePath: filePath) {
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
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
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
                  let targets = computeVisibleTargets(model)
                  if let targetIdx = targets.firstIndex(of: .fileHeader(fileIndex: idx)) {
                    cursorIndex = targetIdx
                  }
                }
            }
          }
          .padding(.horizontal, 8)
        }

        // Right edge: follow toggle + stats
        HStack(spacing: 6) {
          Divider()
            .frame(height: 16)
            .foregroundStyle(Color.panelBorder)

          // Show/hide resolved comments toggle
          if hasResolvedComments {
            Button {
              withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
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
              .frame(height: 12)
              .foregroundStyle(Color.panelBorder)
          }

          if isSessionActive {
            Button {
              isFollowing.toggle()
              if isFollowing, let model = diffModel {
                let targets = computeVisibleTargets(model)
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
        .padding(.trailing, 8)
      }
      .padding(.vertical, Spacing.sm)
    }
    .background(Color.backgroundSecondary)
  }

  private func fileChip(_ file: FileDiff, isSelected: Bool) -> some View {
    let fileName = file.newPath.components(separatedBy: "/").last ?? file.newPath
    let changeColor = chipColor(file.changeType)
    let reviewStatus = isFileAddressed(file.newPath)

    return HStack(spacing: 4) {
      // Review status dot — tiny indicator overlaid on the change bar
      if let addressed = reviewStatus {
        Circle()
          .fill(addressed ? Color.accent : Color.statusQuestion)
          .frame(width: 5, height: 5)
      } else {
        RoundedRectangle(cornerRadius: 1)
          .fill(changeColor)
          .frame(width: 2, height: 14)
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
      HStack(spacing: 3) {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .medium))
        Text(label)
          .font(.system(size: TypeScale.micro, weight: isSelected ? .semibold : .medium))
      }
      .foregroundStyle(isSelected ? Color.accent : .secondary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 3)
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
        let targets = computeVisibleTargets(model)
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
          let targets = computeVisibleTargets(model)
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
      NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [preferredEditor, fullPath]
    try? process.run()
  }
}
