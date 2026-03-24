//
//  MarkdownSegmentView.swift
//  OrbitDock
//
//  Renders stable markdown render segments with a single prose text surface
//  plus dedicated rich block views for code and tables.
//

import SwiftUI

struct MarkdownSegmentView: View {
  let segment: MarkdownRenderSegment
  let style: ContentStyle

  var body: some View {
    switch segment {
      case let .prose(prose):
        Text(MarkdownProseAttributedStringBuilder.build(from: prose.blocks, style: style))
          .lineSpacing(MarkdownTypography.bodyLineSpacing(style: style))
          .fixedSize(horizontal: false, vertical: true)

      case let .codeBlock(codeBlock):
        SwiftUICodeBlockView(language: codeBlock.language, code: codeBlock.code)

      case let .table(table):
        tableView(headers: table.headers, rows: table.rows)

      case .thematicBreak:
        thematicBreakView
    }
  }

  private func tableView(headers: [String], rows: [[String]]) -> some View {
    let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
    let normalizedHeaders = normalizedCells(headers, count: columnCount)
    let normalizedRows = rows.map { normalizedCells($0, count: columnCount) }

    return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow {
        ForEach(0 ..< columnCount, id: \.self) { column in
          Text(MarkdownProseAttributedStringBuilder.inlineMarkdown(normalizedHeaders[column], style: style))
            .font(MarkdownTypography.bodyFont(style: style))
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
      }
      .background(Color.backgroundTertiary.opacity(0.68))

      GridRow {
        Color.surfaceBorder.opacity(0.55).frame(height: 1).gridCellColumns(columnCount)
      }

      ForEach(Array(normalizedRows.enumerated()), id: \.offset) { rowIndex, row in
        GridRow {
          ForEach(0 ..< columnCount, id: \.self) { column in
            Text(MarkdownProseAttributedStringBuilder.inlineMarkdown(row[column], style: style))
              .font(MarkdownTypography.bodyFont(style: style))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
          }
        }
        .background(rowIndex.isMultiple(of: 2)
          ? Color.backgroundSecondary.opacity(0.42)
          : Color.backgroundTertiary.opacity(0.48))

        if rowIndex < normalizedRows.count - 1 {
          GridRow {
            Color.surfaceBorder.opacity(0.55).frame(height: 1).gridCellColumns(columnCount)
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.surfaceBorder.opacity(0.9), lineWidth: 1)
    )
  }

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

  private func normalizedCells(_ cells: [String], count: Int) -> [String] {
    let trimmed = Array(cells.prefix(count))
    if trimmed.count == count { return trimmed }
    return trimmed + Array(repeating: "", count: count - trimmed.count)
  }
}
