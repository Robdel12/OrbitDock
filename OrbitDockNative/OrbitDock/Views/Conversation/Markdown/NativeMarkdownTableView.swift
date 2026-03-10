//
//  NativeMarkdownTableView.swift
//  OrbitDock
//
//  Native markdown table view with content-aware row heights.
//  Cells wrap text instead of truncating for readability.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import SwiftUI

final class NativeMarkdownTableView: PlatformView {
  // MARK: - Constants

  private static let cellVerticalPadding: CGFloat = 10
  private static let cellHorizontalPadding: CGFloat = 14
  private static let borderWidth: CGFloat = 1
  private static let borderColor = PlatformColor(Color.surfaceBorder).withAlphaComponent(0.9)
  private static let gridColor = PlatformColor(Color.surfaceBorder).withAlphaComponent(0.55)
  private static let headerBgColor = PlatformColor(Color.backgroundTertiary).withAlphaComponent(0.68)
  private static let evenRowBgColor = PlatformColor(Color.backgroundSecondary).withAlphaComponent(0.42)
  private static let oddRowBgColor = PlatformColor(Color.backgroundTertiary).withAlphaComponent(0.48)

  // MARK: - Layout Metrics

  private struct TableLayoutMetrics {
    let columnCount: Int
    let columnWidth: CGFloat
    let headerRowHeight: CGFloat
    let dataRowHeights: [CGFloat]

    var totalHeight: CGFloat {
      headerRowHeight + dataRowHeights.reduce(0, +)
    }
  }

  // MARK: - State

  private var headers: [String] = []
  private var rows: [[String]] = []
  private var contentStyle: ContentStyle = .standard

  #if os(macOS)
    override var isFlipped: Bool {
      true
    }
  #endif

  // MARK: - Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if os(macOS)
      wantsLayer = true
      layer?.cornerRadius = 6
      layer?.masksToBounds = true
      layer?.borderWidth = Self.borderWidth
      layer?.borderColor = Self.borderColor.cgColor
    #else
      layer.cornerRadius = 6
      layer.masksToBounds = true
      layer.borderWidth = Self.borderWidth
      layer.borderColor = Self.borderColor.cgColor
    #endif
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  // MARK: - Configure

  func configure(headers: [String], rows: [[String]], style: ContentStyle = .standard) {
    self.headers = headers
    self.rows = rows
    contentStyle = style
    rebuildContent()
  }

  // MARK: - Layout

  private func rebuildContent() {
    subviews.forEach { $0.removeFromSuperview() }

    let metrics = Self.layoutMetrics(headers: headers, rows: rows, width: bounds.width, style: contentStyle)
    guard metrics.columnCount > 0 else { return }

    let normalizedHeaders = Self.normalizedCells(headers, columnCount: metrics.columnCount)
    let normalizedRows = Self.normalizedRows(rows, columnCount: metrics.columnCount)

    var yOffset: CGFloat = 0
    let textWidth = max(1, metrics.columnWidth - Self.cellHorizontalPadding * 2)

    // Header row
    let headerBg = PlatformView(frame: CGRect(x: 0, y: yOffset, width: bounds.width, height: metrics.headerRowHeight))
    #if os(macOS)
      headerBg.wantsLayer = true
      headerBg.layer?.backgroundColor = Self.headerBgColor.cgColor
    #else
      headerBg.backgroundColor = Self.headerBgColor
    #endif
    addSubview(headerBg)

    for col in 0 ..< metrics.columnCount {
      let headerText = MarkdownSystemParser.inlineTableCellText(
        from: normalizedHeaders[col],
        style: contentStyle,
        isHeader: true
      )
      let label = makeLabel(text: headerText)
      label.frame = CGRect(
        x: CGFloat(col) * metrics.columnWidth + Self.cellHorizontalPadding,
        y: yOffset + Self.cellVerticalPadding,
        width: textWidth,
        height: metrics.headerRowHeight - Self.cellVerticalPadding * 2
      )
      addSubview(label)
    }

    addColumnSeparators(
      rowY: yOffset,
      rowHeight: metrics.headerRowHeight,
      columnCount: metrics.columnCount,
      columnWidth: metrics.columnWidth
    )
    yOffset += metrics.headerRowHeight

    // Data rows
    for (rowIndex, row) in normalizedRows.enumerated() {
      let rowHeight = metrics.dataRowHeights[rowIndex]
      let bgColor = rowIndex % 2 == 0 ? Self.evenRowBgColor : Self.oddRowBgColor
      let rowBg = PlatformView(frame: CGRect(x: 0, y: yOffset, width: bounds.width, height: rowHeight))
      #if os(macOS)
        rowBg.wantsLayer = true
        rowBg.layer?.backgroundColor = bgColor.cgColor
      #else
        rowBg.backgroundColor = bgColor
      #endif
      addSubview(rowBg)

      for col in 0 ..< metrics.columnCount {
        let bodyText = MarkdownSystemParser.inlineTableCellText(
          from: row[col],
          style: contentStyle,
          isHeader: false
        )
        let label = makeLabel(text: bodyText)
        label.frame = CGRect(
          x: CGFloat(col) * metrics.columnWidth + Self.cellHorizontalPadding,
          y: yOffset + Self.cellVerticalPadding,
          width: textWidth,
          height: rowHeight - Self.cellVerticalPadding * 2
        )
        addSubview(label)
      }
      addColumnSeparators(
        rowY: yOffset,
        rowHeight: rowHeight,
        columnCount: metrics.columnCount,
        columnWidth: metrics.columnWidth
      )
      addHorizontalSeparator(y: yOffset + rowHeight)
      yOffset += rowHeight
    }
  }

  #if os(macOS)
    private func makeLabel(text: NSAttributedString) -> NSTextField {
      let label = NSTextField(wrappingLabelWithString: "")
      label.allowsEditingTextAttributes = true
      label.attributedStringValue = text
      label.lineBreakMode = .byWordWrapping
      label.maximumNumberOfLines = 0
      label.cell?.usesSingleLineMode = false
      label.cell?.wraps = true
      label.cell?.lineBreakMode = .byWordWrapping
      label.cell?.truncatesLastVisibleLine = false
      return label
    }
  #else
    private func makeLabel(text: NSAttributedString) -> UILabel {
      let label = UILabel()
      label.attributedText = text
      label.lineBreakMode = .byWordWrapping
      label.numberOfLines = 0
      return label
    }
  #endif

  private func addHorizontalSeparator(y: CGFloat) {
    let separator = PlatformView(frame: CGRect(x: 0, y: y - 0.5, width: bounds.width, height: 1))
    #if os(macOS)
      separator.wantsLayer = true
      separator.layer?.backgroundColor = Self.gridColor.cgColor
    #else
      separator.backgroundColor = Self.gridColor
    #endif
    addSubview(separator)
  }

  private func addColumnSeparators(rowY: CGFloat, rowHeight: CGFloat, columnCount: Int, columnWidth: CGFloat) {
    guard columnCount > 1 else { return }
    for column in 1 ..< columnCount {
      let separator = PlatformView(
        frame: CGRect(x: CGFloat(column) * columnWidth - 0.5, y: rowY, width: 1, height: rowHeight)
      )
      #if os(macOS)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Self.gridColor.cgColor
      #else
        separator.backgroundColor = Self.gridColor
      #endif
      addSubview(separator)
    }
  }

  // MARK: - Height Calculation

  static func requiredHeight(
    headers: [String],
    rows: [[String]],
    width: CGFloat,
    style: ContentStyle = .standard
  ) -> CGFloat {
    layoutMetrics(headers: headers, rows: rows, width: width, style: style).totalHeight
  }

  private static func layoutMetrics(
    headers: [String],
    rows: [[String]],
    width: CGFloat,
    style: ContentStyle
  ) -> TableLayoutMetrics {
    let rowColumnCount = rows.map(\.count).max() ?? 0
    let columnCount = max(headers.count, rowColumnCount)
    guard columnCount > 0 else {
      return TableLayoutMetrics(columnCount: 0, columnWidth: 0, headerRowHeight: 0, dataRowHeights: [])
    }

    let contentWidth = max(160, width)
    let columnWidth = max(80, (contentWidth - CGFloat(columnCount + 1) * borderWidth) / CGFloat(columnCount))
    let textWidth = max(1, columnWidth - cellHorizontalPadding * 2)

    let bodyFont = PlatformFont.systemFont(ofSize: style == .thinking ? TypeScale.code : TypeScale.chatBody)
    let headerFont = PlatformFont.systemFont(
      ofSize: style == .thinking ? TypeScale.code : TypeScale.chatBody,
      weight: .semibold
    )
    let bodySingleLine = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
    let headerSingleLine = ceil(headerFont.ascender - headerFont.descender + headerFont.leading)
    let minimumBodyRowHeight = bodySingleLine + cellVerticalPadding * 2
    let minimumHeaderRowHeight = headerSingleLine + cellVerticalPadding * 2

    let normalizedHeaders = normalizedCells(headers, columnCount: columnCount)
    let headerTextHeight = normalizedHeaders
      .map { header in
        textHeight(
          for: MarkdownSystemParser.inlineTableCellText(from: header, style: style, isHeader: true),
          width: textWidth
        )
      }
      .max() ?? headerSingleLine
    let headerRowHeight = max(minimumHeaderRowHeight, headerTextHeight + cellVerticalPadding * 2)

    let normalizedRows = normalizedRows(rows, columnCount: columnCount)
    let dataRowHeights = normalizedRows.map { row -> CGFloat in
      let tallestCell = row
        .map { cell in
          textHeight(
            for: MarkdownSystemParser.inlineTableCellText(from: cell, style: style, isHeader: false),
            width: textWidth
          )
        }
        .max() ?? bodySingleLine
      return max(minimumBodyRowHeight, tallestCell + cellVerticalPadding * 2)
    }

    return TableLayoutMetrics(
      columnCount: columnCount,
      columnWidth: columnWidth,
      headerRowHeight: headerRowHeight,
      dataRowHeights: dataRowHeights
    )
  }

  private static func normalizedRows(_ rows: [[String]], columnCount: Int) -> [[String]] {
    rows.map { normalizedCells($0, columnCount: columnCount) }
  }

  private static func normalizedCells(_ cells: [String], columnCount: Int) -> [String] {
    let trimmed = Array(cells.prefix(columnCount))
    if trimmed.count == columnCount { return trimmed }
    return trimmed + Array(repeating: "", count: columnCount - trimmed.count)
  }

  private static func textHeight(for attributed: NSAttributedString, width: CGFloat) -> CGFloat {
    guard attributed.length > 0 else { return 0 }
    let paragraphStyle = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    let singleLine = ceil(
      (attributed.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont).map {
        $0.ascender - $0.descender + $0.leading
      } ?? 0
    ) + (paragraphStyle?.lineSpacing ?? 0)
    guard width > 1 else { return max(1, singleLine) }

    let rect = attributed.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )

    return max(max(1, singleLine), ceil(rect.height))
  }
}
