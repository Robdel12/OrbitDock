//
//  DiffHunkView.swift
//  OrbitDock
//
//  Renders a single DiffHunk with line numbers, syntax highlighting,
//  and word-level inline change highlights. Supports cursor highlighting
//  for magit-style navigation.
//
//  Performance: Body returns flat views (no wrapping VStack) so that each
//  line becomes a separate lazy item in the parent LazyVStack. Only visible
//  lines incur syntax highlighting and view creation costs.
//

import SwiftUI

struct DiffHunkView<AfterLineContent: View>: View {
  let hunk: DiffHunk
  let language: String
  let hunkIndex: Int
  var fileIndex: Int = 0
  var cursorLineIndex: Int?
  var isCursorOnHeader: Bool = false
  var isHunkCollapsed: Bool = false
  var commentedLines: Set<Int> = [] // newLineNum values with comments
  var selectionLines: Set<Int> = [] // Line indices in mark-to-cursor range
  var composerLineRange: ClosedRange<Int>? // Line indices with active composer
  var onLineComment: ((Int, ClosedRange<Int>) -> Void)? // (clickedLineIdx, smartRange)
  var onLineDragChanged: ((Int, Int) -> Void)? // (anchorLineIdx, currentLineIdx)
  var onLineDragEnded: ((Int, Int) -> Void)? // (startLineIdx, endLineIdx)
  @ViewBuilder var afterLine: (Int, DiffLine) -> AfterLineContent

  // Gutter background — very subtle to define the zone
  private let gutterBg = Color.white.opacity(0.015)
  private let gutterBorder = Color.white.opacity(0.06)

  // MARK: - Body (flat — no VStack wrapper)

  //
  // Returns hunk header + individual line views without a wrapping container.
  // In a parent LazyVStack, each view becomes a separate lazy item so only
  // visible lines are created and highlighted.

  var body: some View {
    hunkHeader
      .id("file-\(fileIndex)-hunk-\(hunkIndex)")
      .overlay {
        if isCursorOnHeader {
          Color.accent.opacity(OpacityTier.subtle)
            .allowsHitTesting(false)
        }
      }

    if !isHunkCollapsed {
      ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
        DiffLineRow(
          line: line,
          index: index,
          hunkLines: hunk.lines,
          language: language,
          isCursor: cursorLineIndex == index,
          hasComment: line.newLineNum.map { commentedLines.contains($0) } ?? false,
          isInSelection: selectionLines.contains(index),
          isInComposerRange: composerLineRange?.contains(index) ?? false,
          onLineComment: onLineComment,
          onLineDragChanged: onLineDragChanged,
          onLineDragEnded: onLineDragEnded
        )
        .id("file-\(fileIndex)-hunk-\(hunkIndex)-line-\(index)")

        // Inline content injected by parent (comments, composer)
        afterLine(index, line)
      }
    }
  }

  // MARK: - Hunk Header

  private var hunkHeader: some View {
    HStack(spacing: 0) {
      // Gutter zone — empty, matching gutter width
      HStack(spacing: 0) {
        Spacer()
      }
      .frame(width: 76)
      .background(gutterBg)

      // Separator continuation
      Rectangle()
        .fill(gutterBorder)
        .frame(width: 1)

      // Header content with decorative lines
      HStack(spacing: 8) {
        // Collapse chevron
        Image(systemName: isHunkCollapsed ? "chevron.right" : "chevron.down")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.accent.opacity(OpacityTier.strong))

        // Left rule
        Rectangle()
          .fill(Color.accent.opacity(OpacityTier.medium))
          .frame(height: 1)
          .frame(maxWidth: 24)

        Text(hunk.header)
          .font(.system(size: TypeScale.body, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.accent.opacity(OpacityTier.vivid))

        if isHunkCollapsed {
          Text("\(hunk.lines.count) lines")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.accent.opacity(OpacityTier.strong))
        }

        // Right rule extends
        Rectangle()
          .fill(Color.accent.opacity(OpacityTier.medium))
          .frame(height: 1)
          .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.md / 2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accent.opacity(OpacityTier.tint))
  }
}

// MARK: - Diff Line Row

//
// Self-contained view for a single diff line. Owns its hover state so that
// hovering one line doesn't cause sibling lines to re-render.

private struct DiffLineRow: View {
  let line: DiffLine
  let index: Int
  let hunkLines: [DiffLine]
  let language: String
  let isCursor: Bool
  let hasComment: Bool
  let isInSelection: Bool
  let isInComposerRange: Bool
  let onLineComment: ((Int, ClosedRange<Int>) -> Void)?
  let onLineDragChanged: ((Int, Int) -> Void)?
  let onLineDragEnded: ((Int, Int) -> Void)?

  @State private var isHovered = false
  @State private var dragAnchor: Int?

  // Design tokens
  private let gutterBg = Color.white.opacity(0.015)
  private let gutterBorder = Color.white.opacity(0.06)

  private var isChanged: Bool {
    line.type == .added || line.type == .removed
  }

  private var isCommentable: Bool {
    line.newLineNum != nil
  }

  private var showAddButton: Bool {
    isHovered && isCommentable && dragAnchor == nil
  }

  var body: some View {
    HStack(spacing: 0) {
      // Left edge accent bar
      Rectangle()
        .fill(hasComment || isInComposerRange ? Color.statusQuestion : edgeBarColor)
        .frame(width: EdgeBar.width)

      // Line number gutter
      HStack(spacing: 0) {
        Text(line.oldLineNum.map { String($0) } ?? "")
          .frame(width: 32, alignment: .trailing)

        // Comment indicator zone
        ZStack {
          if hasComment {
            Circle()
              .fill(Color.statusQuestion)
              .frame(width: 4, height: 4)
          } else if showAddButton {
            Button {
              onLineComment?(index, connectedBlockRange)
            } label: {
              Image(systemName: "plus")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(Color.statusQuestion)
            }
            .buttonStyle(.plain)
            .transition(.opacity)
          }
        }
        .frame(width: 8)

        Text(line.newLineNum.map { String($0) } ?? "")
          .frame(width: 32, alignment: .trailing)
      }
      .font(.system(size: TypeScale.body, design: .monospaced))
      .foregroundStyle(.primary.opacity(isChanged ? OpacityTier.strong : 0.25))
      .background(gutterBg)

      // Gutter/content separator
      Rectangle()
        .fill(gutterBorder)
        .frame(width: 1)

      // Prefix indicator
      Text(line.prefix)
        .font(.system(size: TypeScale.body, weight: .semibold, design: .monospaced))
        .foregroundStyle(prefixColor)
        .frame(width: 20, alignment: .center)

      // Syntax-highlighted code with inline change highlights
      highlightedContent
        .padding(.trailing, Spacing.md)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundColor)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .gesture(
      DragGesture(minimumDistance: 6)
        .onChanged { value in
          guard isCommentable else { return }
          if dragAnchor == nil { dragAnchor = index }
          let lineHeight: CGFloat = 20
          let dragLineOffset = Int(round(value.translation.height / lineHeight))
          let targetLine = max(0, min(index + dragLineOffset, hunkLines.count - 1))
          onLineDragChanged?(dragAnchor ?? index, targetLine)
        }
        .onEnded { value in
          guard isCommentable, let anchor = dragAnchor else { return }
          let lineHeight: CGFloat = 20
          let dragLineOffset = Int(round(value.translation.height / lineHeight))
          let targetLine = max(0, min(index + dragLineOffset, hunkLines.count - 1))
          onLineDragEnded?(min(anchor, targetLine), max(anchor, targetLine))
          dragAnchor = nil
        }
    )
    .overlay {
      if isCursor {
        Color.accent.opacity(OpacityTier.light)
          .allowsHitTesting(false)
      }
    }
    .overlay {
      if isInSelection || isInComposerRange {
        Color.statusQuestion.opacity(isInComposerRange ? 0.10 : 0.18)
          .allowsHitTesting(false)
      }
    }
  }

  // MARK: - Highlighted Content

  @ViewBuilder
  private var highlightedContent: some View {
    let content = line.content.isEmpty ? " " : line.content
    let highlighted = SyntaxHighlighter.highlightLine(content, language: language.isEmpty ? nil : language)
    let inlineRanges = computeInlineRanges()

    if inlineRanges.isEmpty {
      Text(highlighted)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .opacity(line.type == .context ? 0.55 : 1.0)
        .textSelection(.enabled)
    } else {
      Text(applyInlineHighlights(highlighted, ranges: inlineRanges))
        .font(.system(size: TypeScale.code, design: .monospaced))
        .textSelection(.enabled)
    }
  }

  // MARK: - Inline Ranges

  private func applyInlineHighlights(
    _ base: AttributedString,
    ranges: [Range<String.Index>]
  ) -> AttributedString {
    var attributed = base
    let highlightColor = line.type == .added ? Color.diffAddedHighlight : Color.diffRemovedHighlight
    for range in ranges {
      if let attrRange = Range(range, in: attributed) {
        attributed[attrRange].backgroundColor = highlightColor
      }
    }
    return attributed
  }

  /// For adjacent removed+added pairs, compute character-level inline changes.
  private func computeInlineRanges() -> [Range<String.Index>] {
    guard line.type == .removed || line.type == .added else { return [] }

    if line.type == .removed {
      let nextIndex = index + 1
      guard nextIndex < hunkLines.count, hunkLines[nextIndex].type == .added else { return [] }
      if index > 0, hunkLines[index - 1].type == .removed { return [] }
      if nextIndex + 1 < hunkLines.count, hunkLines[nextIndex + 1].type == .added { return [] }
      return DiffModel.inlineChanges(oldLine: line.content, newLine: hunkLines[nextIndex].content).old
    } else {
      let prevIndex = index - 1
      guard prevIndex >= 0, hunkLines[prevIndex].type == .removed else { return [] }
      if prevIndex > 0, hunkLines[prevIndex - 1].type == .removed { return [] }
      if index + 1 < hunkLines.count, hunkLines[index + 1].type == .added { return [] }
      return DiffModel.inlineChanges(oldLine: hunkLines[prevIndex].content, newLine: line.content).new
    }
  }

  // MARK: - Smart Connected Block

  private var connectedBlockRange: ClosedRange<Int> {
    guard line.type != .context else { return index ... index }
    var start = index
    while start > 0, hunkLines[start - 1].type != .context {
      start -= 1
    }
    var end = index
    while end < hunkLines.count - 1, hunkLines[end + 1].type != .context {
      end += 1
    }
    return start ... end
  }

  // MARK: - Colors

  private var edgeBarColor: Color {
    switch line.type {
      case .added: Color.diffAddedEdge
      case .removed: Color.diffRemovedEdge
      case .context: .clear
    }
  }

  private var prefixColor: Color {
    switch line.type {
      case .added: Color.diffAddedAccent
      case .removed: Color.diffRemovedAccent
      case .context: .clear
    }
  }

  private var backgroundColor: Color {
    switch line.type {
      case .added: Color.diffAddedBg
      case .removed: Color.diffRemovedBg
      case .context: .clear
    }
  }
}
