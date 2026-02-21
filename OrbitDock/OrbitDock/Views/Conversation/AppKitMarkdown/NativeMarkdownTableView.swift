//
//  NativeMarkdownTableView.swift
//  OrbitDock
//
//  Simple grid layout for markdown tables with alternating row
//  backgrounds and bordered cells.
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

  // MARK: - State

  private var headers: [String] = []
  private var rows: [[String]] = []

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
    guard !headers.isEmpty else { return }

    let columnCount = headers.count
    let columnWidth = max(80, (bounds.width - CGFloat(columnCount + 1) * Self.borderWidth) / CGFloat(columnCount))
    let rowHeight: CGFloat = Self
      .cellVerticalPadding * 2 + ceil(Self.cellFont.ascender - Self.cellFont.descender + Self.cellFont.leading)

    var yOffset: CGFloat = 0

    // Header row
    let headerBg = PlatformView(frame: CGRect(x: 0, y: yOffset, width: bounds.width, height: rowHeight))
    #if os(macOS)
      headerBg.wantsLayer = true
      headerBg.layer?.backgroundColor = Self.headerBgColor.cgColor
    #else
      headerBg.backgroundColor = Self.headerBgColor
    #endif
    addSubview(headerBg)

    for (col, header) in headers.enumerated() {
      #if os(macOS)
        let label = NSTextField(labelWithString: header)
        label.font = Self.headerFont
        label.textColor = Self.headerTextColor
        label.lineBreakMode = .byTruncatingTail
      #else
        let label = UILabel()
        label.text = header
        label.font = Self.headerFont
        label.textColor = Self.headerTextColor
        label.lineBreakMode = .byTruncatingTail
      #endif
      label.frame = CGRect(
        x: CGFloat(col) * columnWidth + Self.cellHorizontalPadding,
        y: yOffset + Self.cellVerticalPadding,
        width: columnWidth - Self.cellHorizontalPadding * 2,
        height: rowHeight - Self.cellVerticalPadding * 2
      )
      addSubview(label)
    }
    yOffset += rowHeight

    // Data rows
    for (rowIndex, row) in rows.enumerated() {
      let bgColor = rowIndex % 2 == 0 ? Self.evenRowBgColor : Self.oddRowBgColor
      let rowBg = PlatformView(frame: CGRect(x: 0, y: yOffset, width: bounds.width, height: rowHeight))
      #if os(macOS)
        rowBg.wantsLayer = true
        rowBg.layer?.backgroundColor = bgColor.cgColor
      #else
        rowBg.backgroundColor = bgColor
      #endif
      addSubview(rowBg)

      for (col, cell) in row.enumerated() {
        guard col < columnCount else { break }
        #if os(macOS)
          let label = NSTextField(labelWithString: cell)
          label.font = Self.cellFont
          label.textColor = Self.textColor
          label.lineBreakMode = .byTruncatingTail
        #else
          let label = UILabel()
          label.text = cell
          label.font = Self.cellFont
          label.textColor = Self.textColor
          label.lineBreakMode = .byTruncatingTail
        #endif
        label.frame = CGRect(
          x: CGFloat(col) * columnWidth + Self.cellHorizontalPadding,
          y: yOffset + Self.cellVerticalPadding,
          width: columnWidth - Self.cellHorizontalPadding * 2,
          height: rowHeight - Self.cellVerticalPadding * 2
        )
        addSubview(label)
      }
      yOffset += rowHeight
    }
  }

  // MARK: - Height Calculation

  static func requiredHeight(headerCount: Int, rowCount: Int) -> CGFloat {
    let rowHeight = cellVerticalPadding * 2 + ceil(cellFont.ascender - cellFont.descender + cellFont.leading)
    return rowHeight * CGFloat(1 + rowCount) // header + data rows
  }
}
