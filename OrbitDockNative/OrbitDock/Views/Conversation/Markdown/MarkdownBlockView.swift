//
//  MarkdownBlockView.swift
//  OrbitDock
//
//  Core SwiftUI view that renders [MarkdownBlock] as a vertical stack.
//  Uses MarkdownTypography for all font sizes, weights, colors, and spacing.
//
//  Text blocks use SwiftUI's native AttributedString(markdown:) with
//  post-processed inline code styling (SF Mono + warm signal color).
//

import SwiftUI

struct MarkdownBlockView: View {
  let blocks: [MarkdownBlock]
  let style: ContentStyle

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
        let previous = index > 0 ? blocks[index - 1] : nil
        let spacing = MarkdownTypography.interBlockSpacing(
          previous: previous, current: block, style: style
        )

        blockView(block)
          .padding(.top, spacing)
      }
    }
    .tint(Color.markdownLink)
    .textSelection(.enabled)
  }

  // MARK: - Block Rendering

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block {
      case let .text(md):
        inlineMarkdown(md)
          .lineSpacing(MarkdownTypography.bodyLineSpacing(style: style))
          .font(MarkdownTypography.bodyFont(style: style))
          .fixedSize(horizontal: false, vertical: true)

      case let .heading(level, text):
        headingView(level: level, text: text)

      case let .codeBlock(language, code):
        SwiftUICodeBlockView(language: language, code: code)

      case let .blockquote(md):
        blockquoteView(md)

      case let .table(headers, rows):
        tableView(headers: headers, rows: rows)

      case .thematicBreak:
        thematicBreakView

      case let .list(items):
        listView(items)
    }
  }

  // MARK: - Heading

  private func headingView(level: Int, text: String) -> some View {
    Text(text)
      .font(MarkdownTypography.headingFont(level: level, style: style))
      .foregroundStyle(MarkdownTypography.headingColor(level: level))
      .padding(.bottom, MarkdownTypography.headingBottomPadding(level: level, style: style))
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Inline Markdown Rendering

  private func inlineMarkdown(_ text: String) -> Text {
    if var attr = try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) {
      attr = MarkdownTypography.applyInlineCodeStyle(attr, style: style)
      return Text(attr)
    }
    return Text(text)
  }

  // MARK: - Blockquote

  private func blockquoteView(_ md: String) -> some View {
    let barWidth = MarkdownLayoutMetrics.blockquoteBarWidth(style: style)
    let leadingPad = MarkdownLayoutMetrics.blockquoteLeadingPadding(style: style)
    let barColor: Color = style == .thinking
      ? Color.textTertiary.opacity(0.5)
      : Color.accentMuted.opacity(0.9)

    return HStack(alignment: .top, spacing: leadingPad) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(barColor)
        .frame(width: barWidth)

      inlineMarkdown(md)
        .lineSpacing(MarkdownTypography.bodyLineSpacing(style: style))
        .font(MarkdownTypography.bodyFont(style: style))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Table

  private func tableView(headers: [String], rows: [[String]]) -> some View {
    let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
    let nh = normalizedCells(headers, count: columnCount)
    let nr = rows.map { normalizedCells($0, count: columnCount) }

    return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow {
        ForEach(0 ..< columnCount, id: \.self) { col in
          inlineMarkdown(nh[col]).fontWeight(.semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
      }
      .background(Color.backgroundTertiary.opacity(0.68))

      GridRow {
        Color.surfaceBorder.opacity(0.55).frame(height: 1).gridCellColumns(columnCount)
      }

      ForEach(Array(nr.enumerated()), id: \.offset) { rowIndex, row in
        GridRow {
          ForEach(0 ..< columnCount, id: \.self) { col in
            inlineMarkdown(row[col])
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 14).padding(.vertical, 10)
          }
        }
        .background(rowIndex % 2 == 0
          ? Color.backgroundSecondary.opacity(0.42)
          : Color.backgroundTertiary.opacity(0.48))

        if rowIndex < nr.count - 1 {
          GridRow {
            Color.surfaceBorder.opacity(0.55).frame(height: 1).gridCellColumns(columnCount)
          }
        }
      }
    }
    .font(MarkdownTypography.bodyFont(style: style))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.surfaceBorder.opacity(0.9), lineWidth: 1))
  }

  private func normalizedCells(_ cells: [String], count: Int) -> [String] {
    let trimmed = Array(cells.prefix(count))
    if trimmed.count == count { return trimmed }
    return trimmed + Array(repeating: "", count: count - trimmed.count)
  }

  // MARK: - List

  private struct FlatListRow {
    let depth: Int
    let marker: ListMarker
    let content: String
    let continuation: [String]
  }

  private func listView(_ items: [ListItem]) -> some View {
    let flat = Self.flattenItems(items)
    let itemSpacing = MarkdownTypography.listItemSpacing(style: style)
    let markerGap = MarkdownTypography.listMarkerGap(style: style)
    let indent = MarkdownTypography.listIndent(style: style)

    return VStack(alignment: .leading, spacing: itemSpacing) {
      ForEach(Array(flat.enumerated()), id: \.offset) { _, row in
        HStack(alignment: .firstTextBaseline, spacing: markerGap) {
          Text(row.marker.display)
            .font(MarkdownTypography.bodyFont(style: style))
            .foregroundStyle(MarkdownTypography.listMarkerColor(row.marker))
            .fixedSize()

          VStack(alignment: .leading, spacing: 2) {
            inlineMarkdown(row.content)
              .lineSpacing(MarkdownTypography.bodyLineSpacing(style: style))
              .font(MarkdownTypography.bodyFont(style: style))
              .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(row.continuation.enumerated()), id: \.offset) { _, text in
              inlineMarkdown(text)
                .lineSpacing(MarkdownTypography.bodyLineSpacing(style: style))
                .font(MarkdownTypography.bodyFont(style: style))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(.leading, CGFloat(row.depth) * indent)
      }
    }
  }

  private static func flattenItems(_ items: [ListItem]) -> [FlatListRow] {
    var result: [FlatListRow] = []
    flattenRecursive(items, depth: 0, into: &result)
    return result
  }

  private static func flattenRecursive(
    _ items: [ListItem], depth: Int, into result: inout [FlatListRow]
  ) {
    for item in items {
      result.append(
        FlatListRow(
          depth: depth, marker: item.marker,
          content: item.content, continuation: item.continuation
        )
      )
      if !item.children.isEmpty {
        flattenRecursive(item.children, depth: depth + 1, into: &result)
      }
    }
  }

  // MARK: - Thematic Break

  private var thematicBreakView: some View {
    HStack(spacing: 8) {
      Spacer()
      ForEach(0 ..< 3, id: \.self) { _ in
        Circle()
          .fill(Color.textQuaternary.opacity(0.6))
          .frame(width: 4, height: 4)
      }
      Spacer()
    }
  }
}
