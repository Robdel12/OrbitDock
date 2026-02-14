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
//    S            — send all open comments to model as structured review feedback
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
    case .fileHeader(let f): f
    case .hunkHeader(let f, _): f
    case .diffLine(let f, _, _): f
    }
  }

  var scrollId: String {
    switch self {
    case .fileHeader(let f): "file-\(f)"
    case .hunkHeader(let f, let h): "file-\(f)-hunk-\(h)"
    case .diffLine(let f, let h, let l): "file-\(f)-hunk-\(h)-line-\(l)"
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
  let lineStartIdx: Int    // Index in hunk.lines
  let lineEndIdx: Int
  let lineStart: UInt32    // Actual new-side line number for server
  let lineEnd: UInt32?
}

// MARK: - ReviewCanvas

struct ReviewCanvas: View {
  let sessionId: String
  let projectPath: String
  let isSessionActive: Bool
  var compact: Bool = false
  var navigateToFileId: Binding<String?>? = nil
  var onDismiss: (() -> Void)? = nil
  var navigateToComment: Binding<ServerReviewComment?>? = nil

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
    guard let raw = rawDiff, !raw.isEmpty else { return nil }
    return DiffModel.parse(unifiedDiff: raw)
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
        for lineIdx in 0..<hunk.lines.count {
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
    guard case .diffLine(let f, let h, let l) = target, f == fileIdx, h == hunkIdx else { return nil }
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
      if isFollowing && isSessionActive && newFileCount > previousFileCount {
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
        commentCounts: buildCommentCounts()
      )

      Divider()
        .foregroundStyle(Color.panelBorder)

      unifiedDiffView(model)
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
        VStack(alignment: .leading, spacing: 0) {
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
                  selectionLines: selectionLineIndices(fileIdx: fileIdx, hunkIdx: hunkIdx)
                ) { lineIdx, line in
                  // Inline comments
                  if let newLine = line.newLineNum {
                    let lineComments = commentsForLine(filePath: file.newPath, lineNum: newLine)
                    if !lineComments.isEmpty {
                      InlineCommentThread(
                        comments: lineComments,
                        onResolve: { comment in
                          resolveComment(comment)
                        }
                      )
                      .id("comments-\(fileIdx)-\(hunkIdx)-\(lineIdx)")
                    }
                  }

                  // Composer (appears after last line of selection)
                  if let ct = composerTarget,
                     ct.fileIndex == fileIdx,
                     ct.hunkIndex == hunkIdx,
                     ct.lineEndIdx == lineIdx {
                    CommentComposerView(
                      commentBody: $composerBody,
                      tag: $composerTag,
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
      case .fileHeader(let f):
        toggleCollapseAtCursor(model: model, fileIdx: f)
      case .hunkHeader(let f, let h):
        toggleHunkCollapse(model: model, fileIdx: f, hunkIdx: h)
      case .diffLine(let f, let h, _):
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
    let count = obs.reviewComments.filter { $0.status == .open }.count

    return Button(action: sendReview) {
      HStack(spacing: 8) {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 11, weight: .medium))

        Text("Send \(count) comment\(count == 1 ? "" : "s") to model")
          .font(.system(size: 12, weight: .semibold))

        Text("S")
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .foregroundStyle(.white.opacity(0.5))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(Color.statusQuestion, in: Capsule())
      .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
    .buttonStyle(.plain)
    .padding(.bottom, 16)
    .transition(.move(edge: .bottom).combined(with: .opacity))
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: count)
  }

  // MARK: - File Section Header

  private func fileSectionHeader(file: FileDiff, fileIndex: Int, isCursor: Bool) -> some View {
    let isCollapsed = collapsedFiles.contains(file.id)

    return HStack(spacing: 0) {
      // Cursor indicator — accent left bar
      Rectangle()
        .fill(isCursor ? Color.accent : Color.clear)
        .frame(width: 3)

      // Collapse chevron
      Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(isCursor ? Color.accent : Color.white.opacity(0.25))
        .frame(width: 24)

      // Change type icon
      ZStack {
        Circle()
          .fill(changeTypeColor(file.changeType).opacity(0.15))
          .frame(width: 22, height: 22)
        Image(systemName: fileIcon(file.changeType))
          .font(.system(size: 10, weight: .semibold))
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
              .foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.5).opacity(0.7))
            Text("\(file.stats.additions)")
              .foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.5))
          }
        }
        if file.stats.deletions > 0 {
          HStack(spacing: 2) {
            Text("\u{2212}")
              .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5).opacity(0.7))
            Text("\(file.stats.deletions)")
              .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5))
          }
        }
      }
      .font(.system(size: 10, weight: .bold, design: .monospaced))

      Spacer(minLength: 16)

      // Collapsed hunk count hint
      if isCollapsed {
        Text("\(file.hunks.count) hunk\(file.hunks.count == 1 ? "" : "s")")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.tertiary)
          .padding(.trailing, 8)
      }
    }
    .padding(.vertical, 8)
    .padding(.trailing, 8)
    .background(isCursor ? Color.accent.opacity(0.12) : Color.backgroundSecondary)
    .contentShape(Rectangle())
  }

  private func filePathLabel(_ path: String) -> some View {
    let components = path.components(separatedBy: "/")
    let fileName = components.last ?? path
    let dirPath = components.count > 1 ? components.dropLast().joined(separator: "/") + "/" : ""

    return HStack(spacing: 0) {
      if !dirPath.isEmpty {
        Text(dirPath)
          .font(.system(size: 11, weight: .regular, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
      Text(fileName)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
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

    // Shift+S — send review (all open comments) to model
    if keyPress.key == "S", keyPress.modifiers == .shift {
      sendReview()
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
      for i in (safeIdx + 1)..<targets.count {
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
  private func commentsForLine(filePath: String, lineNum: Int) -> [ServerReviewComment] {
    obs.reviewComments.filter { comment in
      comment.filePath == filePath &&
      Int(comment.lineEnd ?? comment.lineStart) == lineNum
    }
  }

  /// Build a map of filePath → comment count for the file list.
  private func buildCommentCounts() -> [String: Int] {
    var counts: [String: Int] = [:]
    for comment in obs.reviewComments {
      counts[comment.filePath, default: 0] += 1
    }
    return counts
  }

  /// Set of new-side line numbers that have comments for a given file.
  /// Marks ALL lines in the range (not just lineStart) for purple indicator.
  private func commentedNewLineNums(forFile filePath: String) -> Set<Int> {
    var result = Set<Int>()
    for comment in obs.reviewComments where comment.filePath == filePath {
      let start = Int(comment.lineStart)
      let end = Int(comment.lineEnd ?? comment.lineStart)
      for line in start...end {
        result.insert(line)
      }
    }
    return result
  }

  /// Set of line indices within a hunk that fall in the mark-to-cursor selection range.
  private func selectionLineIndices(fileIdx: Int, hunkIdx: Int) -> Set<Int> {
    guard let mark = commentMark else { return [] }
    guard let model = diffModel else { return [] }
    guard case .diffLine(let mf, let mh, let ml) = mark else { return [] }
    guard let target = currentTarget(model) else { return [] }
    guard case .diffLine(let cf, let ch, let cl) = target else { return [] }

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
      return Set(min(startLine, endLine)...max(startLine, endLine))
    }

    // Cross-hunk selection
    if hunkIdx == startHunk {
      let hunkLineCount = model.files[fileIdx].hunks[hunkIdx].lines.count
      let sl = mh < ch ? ml : cl
      return Set(sl..<hunkLineCount)
    } else if hunkIdx == endHunk {
      let el = mh < ch ? cl : ml
      return Set(0...el)
    } else {
      // Entire hunk is in selection
      let hunkLineCount = model.files[fileIdx].hunks[hunkIdx].lines.count
      return Set(0..<hunkLineCount)
    }
  }

  /// Check if a cursor target (diffLine) has a non-nil newLineNum.
  private func diffLineHasNewLineNum(_ target: CursorTarget, model: DiffModel) -> Bool {
    guard case .diffLine(let f, let h, let l) = target else { return false }
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
      guard case .diffLine(let mf, let mh, let ml) = mark,
            case .diffLine(let cf, let ch, let cl) = target,
            mf == cf else {
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
    guard case .diffLine(let f, let h, let l) = target else { return .ignored }
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
  private func submitComment() {
    guard let ct = composerTarget else { return }
    let trimmed = composerBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    serverState.createReviewComment(
      sessionId: sessionId,
      turnId: nil,
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
          case .diffLine(let f, _, _) = target else { return }

    let file = model.files[f]
    guard case .diffLine(_, let h, let l) = target else { return }
    let line = file.hunks[h].lines[l]
    guard let newLine = line.newLineNum else { return }

    let lineComments = commentsForLine(filePath: file.newPath, lineNum: newLine)
    if let first = lineComments.first(where: { $0.status == .open }) {
      resolveComment(first)
    } else if let first = lineComments.first {
      resolveComment(first)
    }
  }

  /// Jump cursor to the next/prev diff line that has an unresolved comment.
  private func jumpToNextComment(forward: Bool, in model: DiffModel) {
    let targets = computeVisibleTargets(model)
    guard !targets.isEmpty else { return }
    let safeIdx = min(cursorIndex, targets.count - 1)

    let unresolvedFiles = buildUnresolvedCommentLineMap(model: model)

    let range = forward
      ? Array((safeIdx + 1)..<targets.count) + Array(0..<safeIdx)
      : (Array(stride(from: safeIdx - 1, through: 0, by: -1)) + Array(stride(from: targets.count - 1, through: safeIdx + 1, by: -1)))

    for i in range {
      guard case .diffLine(let f, let h, let l) = targets[i] else { continue }
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
  private func buildUnresolvedCommentLineMap(model: DiffModel) -> [String: Set<Int>] {
    var map: [String: Set<Int>] = [:]
    for comment in obs.reviewComments where comment.status == .open {
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
  private func formatReviewMessage() -> String? {
    let openComments = obs.reviewComments.filter { $0.status == .open }
    guard !openComments.isEmpty else { return nil }

    let model = diffModel

    // Group by file path, preserving order of first appearance
    var fileOrder: [String] = []
    var grouped: [String: [ServerReviewComment]] = [:]
    for comment in openComments {
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
        let lineRef: String
        if let end = comment.lineEnd, end != comment.lineStart {
          lineRef = "Lines \(comment.lineStart)–\(end)"
        } else {
          lineRef = "Line \(comment.lineStart)"
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

    // No trailing instruction — the code + comments speak for themselves
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
          if !extracted.isEmpty && line.type == .removed {
            extracted.append("\(line.prefix)\(line.content)")
          }
          continue
        }
        if newNum >= lineStart && newNum <= end {
          extracted.append("\(line.prefix)\(line.content)")
        }
      }
    }

    return extracted.isEmpty ? nil : extracted.joined(separator: "\n")
  }

  /// Send all open review comments as structured feedback to the model, then resolve them.
  private func sendReview() {
    guard let message = formatReviewMessage() else { return }

    serverState.sendMessage(sessionId: sessionId, content: message)

    // Mark all open comments as resolved after sending
    for comment in obs.reviewComments where comment.status == .open {
      serverState.updateReviewComment(
        commentId: comment.id,
        body: nil,
        tag: nil,
        status: .resolved
      )
    }
  }

  private var hasOpenComments: Bool {
    obs.reviewComments.contains { $0.status == .open }
  }

  // MARK: - Compact File Strip

  private func compactFileStrip(_ model: DiffModel) -> some View {
    let cursorFileIdx = currentFileIndex(model)

    return VStack(spacing: 0) {
      // Source selector row
      if !obs.turnDiffs.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 3) {
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
          HStack(spacing: 3) {
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
              HStack(spacing: 3) {
                Circle()
                  .fill(isFollowing ? Color.accent : Color.white.opacity(0.2))
                  .frame(width: 5, height: 5)
                Text(isFollowing ? "Following" : "Paused")
                  .font(.system(size: 9, weight: .medium))
                  .foregroundStyle(isFollowing ? Color.accent : Color.white.opacity(0.3))
              }
            }
            .buttonStyle(.plain)
          }

          let totalAdds = model.files.reduce(0) { $0 + $1.stats.additions }
          let totalDels = model.files.reduce(0) { $0 + $1.stats.deletions }

          HStack(spacing: 3) {
            Text("+\(totalAdds)")
              .foregroundStyle(Color(red: 0.4, green: 0.95, blue: 0.5).opacity(0.8))
            Text("\u{2212}\(totalDels)")
              .foregroundStyle(Color(red: 1.0, green: 0.5, blue: 0.5).opacity(0.8))
          }
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .padding(.trailing, 8)
      }
      .padding(.vertical, 5)
    }
    .background(Color.backgroundSecondary)
  }

  private func fileChip(_ file: FileDiff, isSelected: Bool) -> some View {
    let fileName = file.newPath.components(separatedBy: "/").last ?? file.newPath
    let changeColor = chipColor(file.changeType)

    return HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 1)
        .fill(changeColor)
        .frame(width: 2, height: 14)

      Text(fileName)
        .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .monospaced))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .lineLimit(1)

      if file.stats.additions + file.stats.deletions > 0 {
        HStack(spacing: 0) {
          if file.stats.additions > 0 {
            RoundedRectangle(cornerRadius: 0.5)
              .fill(Color(red: 0.3, green: 0.78, blue: 0.4))
              .frame(
                width: microBarWidth(count: file.stats.additions, total: file.stats.additions + file.stats.deletions),
                height: 3
              )
          }
          if file.stats.deletions > 0 {
            RoundedRectangle(cornerRadius: 0.5)
              .fill(Color(red: 0.85, green: 0.35, blue: 0.35))
              .frame(
                width: microBarWidth(count: file.stats.deletions, total: file.stats.additions + file.stats.deletions),
                height: 3
              )
          }
        }
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(isSelected ? Color.accent.opacity(0.12) : Color.backgroundTertiary.opacity(0.5))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .strokeBorder(isSelected ? Color.accent.opacity(0.3) : Color.clear, lineWidth: 1)
    )
  }

  private func microBarWidth(count: Int, total: Int) -> CGFloat {
    guard total > 0 else { return 0 }
    return max(3, CGFloat(count) / CGFloat(total) * 16)
  }

  private func chipColor(_ type: FileChangeType) -> Color {
    switch type {
    case .added: Color(red: 0.3, green: 0.78, blue: 0.4)
    case .deleted: Color(red: 0.85, green: 0.35, blue: 0.35)
    case .renamed, .modified: Color.accent
    }
  }

  private func compactSourceButton(label: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 3) {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .medium))
        Text(label)
          .font(.system(size: 9, weight: isSelected ? .semibold : .medium))
      }
      .foregroundStyle(isSelected ? Color.accent : .secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        isSelected ? Color.accent.opacity(0.15) : Color.backgroundTertiary.opacity(0.5),
        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .strokeBorder(isSelected ? Color.accent.opacity(0.2) : Color.clear, lineWidth: 1)
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
    case .added: Color(red: 0.4, green: 0.95, blue: 0.5)
    case .deleted: Color(red: 1.0, green: 0.5, blue: 0.5)
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
