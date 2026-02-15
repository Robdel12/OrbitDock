//
//  DiffHunkView.swift
//  OrbitDock
//
//  Renders a single DiffHunk with line numbers, syntax highlighting,
//  and word-level inline change highlights. Supports cursor highlighting
//  for magit-style navigation.
//

import SwiftUI

struct DiffHunkView<AfterLineContent: View>: View {
  let hunk: DiffHunk
  let language: String
  let hunkIndex: Int
  var fileIndex: Int = 0
  var cursorLineIndex: Int? = nil
  var isCursorOnHeader: Bool = false
  var isHunkCollapsed: Bool = false
  var commentedLines: Set<Int> = []    // newLineNum values with comments
  var selectionLines: Set<Int> = []    // Line indices in mark-to-cursor range
  var composerLineRange: ClosedRange<Int>? = nil  // Line indices with active composer
  var onLineComment: ((Int, ClosedRange<Int>) -> Void)? = nil  // (clickedLineIdx, smartRange)
  var onLineDragChanged: ((Int, Int) -> Void)? = nil            // (anchorLineIdx, currentLineIdx)
  var onLineDragEnded: ((Int, Int) -> Void)? = nil              // (startLineIdx, endLineIdx)
  @ViewBuilder var afterLine: (Int, DiffLine) -> AfterLineContent

  // Diff colors from design tokens
  private let addedBg = Color.diffAddedBg
  private let removedBg = Color.diffRemovedBg
  private let addedAccent = Color.diffAddedAccent
  private let removedAccent = Color.diffRemovedAccent
  private let addedEdge = Color.diffAddedEdge
  private let removedEdge = Color.diffRemovedEdge

  // Gutter background — very subtle to define the zone
  private let gutterBg = Color.white.opacity(0.015)
  private let gutterBorder = Color.white.opacity(0.06)

  @State private var hoveredLineIndex: Int? = nil
  @State private var dragAnchor: Int? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
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
          diffLineRow(line, index: index)
            .id("file-\(fileIndex)-hunk-\(hunkIndex)-line-\(index)")
            .overlay {
              if cursorLineIndex == index {
                Color.accent.opacity(OpacityTier.light)
                  .allowsHitTesting(false)
              }
            }

          // Inline content injected by parent (comments, composer)
          afterLine(index, line)
        }
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

  // MARK: - Diff Line Row

  private func diffLineRow(_ line: DiffLine, index: Int) -> some View {
    let inlineRanges = computeInlineRanges(for: line, at: index)
    let isChanged = line.type == .added || line.type == .removed
    let hasComment = line.newLineNum.map { commentedLines.contains($0) } ?? false
    let isInSelection = selectionLines.contains(index)
    let isInComposerRange = composerLineRange?.contains(index) ?? false
    let isCommentable = line.newLineNum != nil
    let isHovered = hoveredLineIndex == index
    let showAddButton = isHovered && isCommentable && dragAnchor == nil

    return HStack(spacing: 0) {
      // Left edge accent bar; purple for commented/composer lines, else add/remove color
      Rectangle()
        .fill(hasComment || isInComposerRange ? Color.statusQuestion : edgeBarColor(for: line.type))
        .frame(width: EdgeBar.width)

      // Line number gutter
      HStack(spacing: 0) {
        // Old line number
        Text(line.oldLineNum.map { String($0) } ?? "")
          .frame(width: 32, alignment: .trailing)

        // Comment indicator — always takes space, content changes on hover
        ZStack {
          if hasComment {
            Circle()
              .fill(Color.statusQuestion)
              .frame(width: 4, height: 4)
          } else if showAddButton {
            Button {
              let range = connectedBlockRange(for: index)
              onLineComment?(index, range)
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

        // New line number
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
        .foregroundStyle(prefixColor(for: line.type))
        .frame(width: 20, alignment: .center)

      // Syntax-highlighted code with inline change highlights
      inlineHighlightedContent(line: line, ranges: inlineRanges)
        .padding(.trailing, Spacing.md)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundColor(for: line.type))
    .contentShape(Rectangle())
    .onHover { hovering in
      hoveredLineIndex = hovering ? index : nil
    }
    .gesture(
      DragGesture(minimumDistance: 6)
        .onChanged { value in
          guard isCommentable else { return }
          if dragAnchor == nil { dragAnchor = index }
          let lineHeight: CGFloat = 20
          let dragLineOffset = Int(round(value.translation.height / lineHeight))
          let targetLine = max(0, min(index + dragLineOffset, hunk.lines.count - 1))
          onLineDragChanged?(dragAnchor ?? index, targetLine)
        }
        .onEnded { value in
          guard isCommentable, let anchor = dragAnchor else { return }
          let lineHeight: CGFloat = 20
          let dragLineOffset = Int(round(value.translation.height / lineHeight))
          let targetLine = max(0, min(index + dragLineOffset, hunk.lines.count - 1))
          onLineDragEnded?(min(anchor, targetLine), max(anchor, targetLine))
          dragAnchor = nil
        }
    )
    .overlay {
      if isInSelection || isInComposerRange {
        Color.statusQuestion.opacity(isInComposerRange ? 0.10 : 0.18)
          .allowsHitTesting(false)
      }
    }
  }

  // MARK: - Smart Connected Block

  /// Find the contiguous change block (removed+added) around the given line index.
  /// If the line is a context line, returns just that single line.
  private func connectedBlockRange(for index: Int) -> ClosedRange<Int> {
    let line = hunk.lines[index]
    guard line.type != .context else { return index...index }

    // Walk backward to find start of change block
    var start = index
    while start > 0 && hunk.lines[start - 1].type != .context {
      start -= 1
    }

    // Walk forward to find end of change block
    var end = index
    while end < hunk.lines.count - 1 && hunk.lines[end + 1].type != .context {
      end += 1
    }

    return start...end
  }

  // MARK: - Inline Highlights

  @ViewBuilder
  private func inlineHighlightedContent(line: DiffLine, ranges: [Range<String.Index>]) -> some View {
    let content = line.content.isEmpty ? " " : line.content
    let highlighted = SyntaxHighlighter.highlightLine(content, language: language.isEmpty ? nil : language)

    if ranges.isEmpty {
      Text(highlighted)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .opacity(line.type == .context ? 0.55 : 1.0)
        .textSelection(.enabled)
    } else {
      // Apply inline change highlights on top of syntax highlighting
      Text(applyInlineHighlights(highlighted, ranges: ranges, lineType: line.type))
        .font(.system(size: TypeScale.code, design: .monospaced))
        .textSelection(.enabled)
    }
  }

  private func applyInlineHighlights(_ base: AttributedString, ranges: [Range<String.Index>], lineType: DiffLineType) -> AttributedString {
    var attributed = base
    let highlightColor = lineType == .added ? Color.diffAddedHighlight : Color.diffRemovedHighlight

    for range in ranges {
      if let attrRange = Range(range, in: attributed) {
        attributed[attrRange].backgroundColor = highlightColor
      }
    }
    return attributed
  }

  /// For adjacent removed+added pairs, compute character-level inline changes.
  private func computeInlineRanges(for line: DiffLine, at index: Int) -> [Range<String.Index>] {
    guard line.type == .removed || line.type == .added else { return [] }

    let lines = hunk.lines

    if line.type == .removed {
      let nextIndex = index + 1
      guard nextIndex < lines.count, lines[nextIndex].type == .added else { return [] }
      if index > 0, lines[index - 1].type == .removed { return [] }
      if nextIndex + 1 < lines.count, lines[nextIndex + 1].type == .added { return [] }

      let result = DiffModel.inlineChanges(oldLine: line.content, newLine: lines[nextIndex].content)
      return result.old
    } else {
      let prevIndex = index - 1
      guard prevIndex >= 0, lines[prevIndex].type == .removed else { return [] }
      if prevIndex > 0, lines[prevIndex - 1].type == .removed { return [] }
      if index + 1 < lines.count, lines[index + 1].type == .added { return [] }

      let result = DiffModel.inlineChanges(oldLine: lines[prevIndex].content, newLine: line.content)
      return result.new
    }
  }

  // MARK: - Colors

  private func edgeBarColor(for type: DiffLineType) -> Color {
    switch type {
    case .added: addedEdge
    case .removed: removedEdge
    case .context: .clear
    }
  }

  private func prefixColor(for type: DiffLineType) -> Color {
    switch type {
    case .added: addedAccent
    case .removed: removedAccent
    case .context: .clear
    }
  }

  private func backgroundColor(for type: DiffLineType) -> Color {
    switch type {
    case .added: addedBg
    case .removed: removedBg
    case .context: .clear
    }
  }
}
