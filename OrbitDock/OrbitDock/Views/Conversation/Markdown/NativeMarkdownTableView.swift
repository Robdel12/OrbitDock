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

  private static let cellVerticalPadding: CGFloat = 8
  private static let cellHorizontalPadding: CGFloat = 12
  private static let borderWidth: CGFloat = 1
  private static let borderColor = PlatformColor.white.withAlphaComponent(0.12)
  private static let headerBgColor = PlatformColor.white.withAlphaComponent(0.05)
  private static let evenRowBgColor = PlatformColor.white.withAlphaComponent(0.02)
  private static let oddRowBgColor = PlatformColor.white.withAlphaComponent(0.05)
  private static let cellFont = PlatformFont.systemFont(ofSize: TypeScale.chatBody)
  private static let headerFont = PlatformFont.systemFont(ofSize: TypeScale.chatBody, weight: .semibold)
  private static let textColor = PlatformColor(Color.textPrimary)
  private static let headerTextColor = PlatformColor(Color.textPrimary)

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

  func configure(headers: [String], rows: [[String]]) {
    self.headers = headers
    self.rows = rows
    rebuildContent()
  }

  // MARK: - Layout

  private func rebuildContent() {
    subviews.forEach { $0.removeFromSuperview() }

    let metrics = Self.layoutMetrics(headers: headers, rows: rows, width: bounds.width)
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
      let label = makeLabel(text: normalizedHeaders[col], isHeader: true)
      label.frame = CGRect(
        x: CGFloat(col) * metrics.columnWidth + Self.cellHorizontalPadding,
        y: yOffset + Self.cellVerticalPadding,
        width: textWidth,
        height: metrics.headerRowHeight - Self.cellVerticalPadding * 2
      )
      addSubview(label)
    }
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
        let label = makeLabel(text: row[col], isHeader: false)
        label.frame = CGRect(
          x: CGFloat(col) * metrics.columnWidth + Self.cellHorizontalPadding,
          y: yOffset + Self.cellVerticalPadding,
          width: textWidth,
          height: rowHeight - Self.cellVerticalPadding * 2
        )
        addSubview(label)
      }
      yOffset += rowHeight
    }
  }

  #if os(macOS)
    private func makeLabel(text: String, isHeader: Bool) -> NSTextField {
      let label = NSTextField(wrappingLabelWithString: text)
      label.font = isHeader ? Self.headerFont : Self.cellFont
      label.textColor = isHeader ? Self.headerTextColor : Self.textColor
      label.lineBreakMode = .byWordWrapping
      label.maximumNumberOfLines = 0
      label.cell?.usesSingleLineMode = false
      label.cell?.wraps = true
      label.cell?.lineBreakMode = .byWordWrapping
      label.cell?.truncatesLastVisibleLine = false
      return label
    }
  #else
    private func makeLabel(text: String, isHeader: Bool) -> UILabel {
      let label = UILabel()
      label.text = text
      label.font = isHeader ? Self.headerFont : Self.cellFont
      label.textColor = isHeader ? Self.headerTextColor : Self.textColor
      label.lineBreakMode = .byWordWrapping
      label.numberOfLines = 0
      return label
    }
  #endif

  // MARK: - Height Calculation

  static func requiredHeight(headers: [String], rows: [[String]], width: CGFloat) -> CGFloat {
    layoutMetrics(headers: headers, rows: rows, width: width).totalHeight
  }

  private static func layoutMetrics(headers: [String], rows: [[String]], width: CGFloat) -> TableLayoutMetrics {
    let rowColumnCount = rows.map(\.count).max() ?? 0
    let columnCount = max(headers.count, rowColumnCount)
    guard columnCount > 0 else {
      return TableLayoutMetrics(columnCount: 0, columnWidth: 0, headerRowHeight: 0, dataRowHeights: [])
    }

    let contentWidth = max(160, width)
    let columnWidth = max(80, (contentWidth - CGFloat(columnCount + 1) * borderWidth) / CGFloat(columnCount))
    let textWidth = max(1, columnWidth - cellHorizontalPadding * 2)

    let bodySingleLine = ceil(cellFont.ascender - cellFont.descender + cellFont.leading)
    let headerSingleLine = ceil(headerFont.ascender - headerFont.descender + headerFont.leading)
    let minimumBodyRowHeight = bodySingleLine + cellVerticalPadding * 2
    let minimumHeaderRowHeight = headerSingleLine + cellVerticalPadding * 2

    let normalizedHeaders = normalizedCells(headers, columnCount: columnCount)
    let headerTextHeight = normalizedHeaders
      .map { textHeight(for: $0, font: headerFont, width: textWidth) }
      .max() ?? headerSingleLine
    let headerRowHeight = max(minimumHeaderRowHeight, headerTextHeight + cellVerticalPadding * 2)

    let normalizedRows = normalizedRows(rows, columnCount: columnCount)
    let dataRowHeights = normalizedRows.map { row -> CGFloat in
      let tallestCell = row
        .map { textHeight(for: $0, font: cellFont, width: textWidth) }
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

  private static func textHeight(for text: String, font: PlatformFont, width: CGFloat) -> CGFloat {
    let singleLine = ceil(font.ascender - font.descender + font.leading)
    guard width > 1, !text.isEmpty else { return singleLine }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byWordWrapping

    let attributed = NSAttributedString(string: text, attributes: [
      .font: font,
      .paragraphStyle: paragraphStyle,
    ])

    let rect = attributed.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )

    return max(singleLine, ceil(rect.height))
  }
}
