//
//  DiffHunkView.swift
//  OrbitDock
//
//  Renders a single DiffHunk with line numbers, syntax highlighting,
//  and word-level inline change highlights. Supports cursor highlighting
//  for magit-style navigation.
//

import SwiftUI

struct DiffHunkView: View {
  let hunk: DiffHunk
  let language: String
  let hunkIndex: Int
  var fileIndex: Int = 0
  var cursorLineIndex: Int? = nil
  var isCursorOnHeader: Bool = false
  var isHunkCollapsed: Bool = false

  // Diff background colors — muted, translucent washes
  private let addedBg = Color(red: 0.12, green: 0.26, blue: 0.15).opacity(0.55)
  private let removedBg = Color(red: 0.30, green: 0.12, blue: 0.12).opacity(0.55)

  // Accent colors for prefixes, inline highlights, and edge bars
  private let addedAccent = Color(red: 0.4, green: 0.95, blue: 0.5)
  private let removedAccent = Color(red: 1.0, green: 0.5, blue: 0.5)

  // Left-edge bar colors (saturated, opaque)
  private let addedEdge = Color(red: 0.3, green: 0.78, blue: 0.4)
  private let removedEdge = Color(red: 0.85, green: 0.35, blue: 0.35)

  // Gutter background — very subtle to define the zone
  private let gutterBg = Color.white.opacity(0.015)
  private let gutterBorder = Color.white.opacity(0.06)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      hunkHeader
        .id("file-\(fileIndex)-hunk-\(hunkIndex)")
        .overlay {
          if isCursorOnHeader {
            Color.accent.opacity(0.08)
              .allowsHitTesting(false)
          }
        }

      if !isHunkCollapsed {
        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
          diffLineRow(line, index: index)
            .id("file-\(fileIndex)-hunk-\(hunkIndex)-line-\(index)")
            .overlay {
              if cursorLineIndex == index {
                Color.accent.opacity(0.08)
                  .allowsHitTesting(false)
              }
            }
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
          .foregroundStyle(Color.accent.opacity(0.4))

        // Left rule
        Rectangle()
          .fill(Color.accent.opacity(0.2))
          .frame(height: 1)
          .frame(maxWidth: 24)

        Text(hunk.header)
          .font(.system(size: 10.5, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.accent.opacity(0.7))

        if isHunkCollapsed {
          Text("\(hunk.lines.count) lines")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.accent.opacity(0.4))
        }

        // Right rule extends
        Rectangle()
          .fill(Color.accent.opacity(0.2))
          .frame(height: 1)
          .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accent.opacity(0.04))
  }

  // MARK: - Diff Line Row

  private func diffLineRow(_ line: DiffLine, index: Int) -> some View {
    let inlineRanges = computeInlineRanges(for: line, at: index)
    let isChanged = line.type == .added || line.type == .removed

    return HStack(spacing: 0) {
      // Left edge accent bar — 3px, only on changed lines
      Rectangle()
        .fill(edgeBarColor(for: line.type))
        .frame(width: 3)

      // Line number gutter
      HStack(spacing: 0) {
        // Old line number
        Text(line.oldLineNum.map { String($0) } ?? "")
          .frame(width: 36, alignment: .trailing)

        // New line number
        Text(line.newLineNum.map { String($0) } ?? "")
          .frame(width: 36, alignment: .trailing)
      }
      .font(.system(size: 10.5, design: .monospaced))
      .foregroundStyle(.primary.opacity(isChanged ? 0.4 : 0.25))
      .background(gutterBg)

      // Gutter/content separator
      Rectangle()
        .fill(gutterBorder)
        .frame(width: 1)

      // Prefix indicator
      Text(line.prefix)
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(prefixColor(for: line.type))
        .frame(width: 20, alignment: .center)

      // Syntax-highlighted code with inline change highlights
      inlineHighlightedContent(line: line, ranges: inlineRanges)
        .padding(.trailing, 12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundColor(for: line.type))
  }

  // MARK: - Inline Highlights

  @ViewBuilder
  private func inlineHighlightedContent(line: DiffLine, ranges: [Range<String.Index>]) -> some View {
    let content = line.content.isEmpty ? " " : line.content
    let highlighted = SyntaxHighlighter.highlightLine(content, language: language.isEmpty ? nil : language)

    if ranges.isEmpty {
      Text(highlighted)
        .font(.system(size: 12, design: .monospaced))
        .opacity(line.type == .context ? 0.55 : 1.0)
        .textSelection(.enabled)
    } else {
      // Apply inline change highlights on top of syntax highlighting
      Text(applyInlineHighlights(highlighted, ranges: ranges, lineType: line.type))
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
    }
  }

  private func applyInlineHighlights(_ base: AttributedString, ranges: [Range<String.Index>], lineType: DiffLineType) -> AttributedString {
    var attributed = base
    let accentColor = lineType == .added ? addedAccent : removedAccent

    for range in ranges {
      if let attrRange = Range(range, in: attributed) {
        attributed[attrRange].backgroundColor = accentColor.opacity(0.35)
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
