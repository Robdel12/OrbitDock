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

// MARK: - ReviewCanvas

struct ReviewCanvas: View {
  let sessionId: String
  let projectPath: String
  let isSessionActive: Bool
  var compact: Bool = false
  var navigateToFileId: Binding<String?>? = nil
  var onDismiss: (() -> Void)? = nil

  @Environment(ServerAppState.self) private var serverState

  @State private var cursorIndex: Int = 0
  @State private var collapsedFiles: Set<String> = []
  @State private var collapsedHunks: Set<String> = []
  @State private var expandedContextBars: Set<String> = []
  @State private var selectedTurnDiffId: String?
  @State private var isFollowing = true
  @State private var previousFileCount = 0
  @FocusState private var isCanvasFocused: Bool

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
        selectedTurnDiffId: $selectedTurnDiffId
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

                DiffHunkView(
                  hunk: hunk,
                  language: language,
                  hunkIndex: hunk.id,
                  fileIndex: fileIdx,
                  cursorLineIndex: cursorLineForHunk(fileIdx: fileIdx, hunkIdx: hunkIdx, target: target),
                  isCursorOnHeader: isCursorOnHunkHeader(fileIdx: fileIdx, hunkIdx: hunkIdx, target: target),
                  isHunkCollapsed: collapsedHunks.contains("\(fileIdx)-\(hunkIdx)")
                )
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
    .onKeyPress(keys: [.tab]) { _ in
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
      guard let model = diffModel, let file = currentFile(model) else { return .ignored }
      openFileInEditor(file)
      return .handled
    }
    .onKeyPress { keyPress in
      guard let model = diffModel else { return .ignored }
      return handleKeyPress(keyPress, model: model)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    .background(isCursor ? Color.accent.opacity(0.06) : Color.backgroundSecondary)
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
  // n / p        — jump cursor to next/prev section (file + hunk headers)
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
