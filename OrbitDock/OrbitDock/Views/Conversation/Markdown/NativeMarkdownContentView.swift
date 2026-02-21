//
//  NativeMarkdownContentView.swift
//  OrbitDock
//
//  PlatformView subclass that renders [MarkdownBlock] as a vertical stack
//  of native views. Each block type maps to a purpose-built subview —
//  zero hosting view instances.
//
//  Exposes `requiredHeight(for width:)` for deterministic height
//  calculation using NSLayoutManager / TextKit 1.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import SwiftUI

final class NativeMarkdownContentView: PlatformView {
  // MARK: - Constants

  /// Minimum gap between consecutive .text blocks when the trailing
  /// paragraphSpacing from the attributed string is smaller.
  private static let minimumTextBlockSpacing: CGFloat = 8
  private static let blockquoteBarWidth: CGFloat = 3
  private static let blockquoteBarColor = PlatformColor(Color.accentMuted).withAlphaComponent(0.9)
  private static let blockquoteLeadingPad: CGFloat = 14
  private static let thematicBreakHeight: CGFloat = 28 // 14pt top + 4pt dots + 14pt bottom (approx)
  private static let codeBlockVerticalMargin: CGFloat = 12
  private static let tableVerticalMargin: CGFloat = 12
  private static let blockquoteVerticalMargin: CGFloat = 10

  #if os(macOS)
    override var isFlipped: Bool {
      true
    }
  #endif

  // MARK: - State

  private var blocks: [MarkdownBlock] = []

  // MARK: - Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if os(macOS)
      wantsLayer = true
      layer?.backgroundColor = PlatformColor.clear.cgColor
    #else
      backgroundColor = .clear
    #endif
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  // MARK: - Configure

  func configure(blocks: [MarkdownBlock]) {
    self.blocks = blocks
    rebuildSubviews()
  }

  /// Extract the trailing paragraphSpacing from the last paragraph in an
  /// attributed string. NSLayoutManager ignores this for the final paragraph,
  /// so we apply it as view-level spacing between blocks.
  private static func trailingSpacing(_ attrStr: NSAttributedString) -> CGFloat {
    guard attrStr.length > 0 else { return 0 }
    if let ps = attrStr.attribute(.paragraphStyle, at: attrStr.length - 1, effectiveRange: nil) as? NSParagraphStyle {
      return max(minimumTextBlockSpacing, ps.paragraphSpacing)
    }
    return minimumTextBlockSpacing
  }

  private func rebuildSubviews() {
    subviews.forEach { $0.removeFromSuperview() }
    guard !blocks.isEmpty else { return }

    var yOffset: CGFloat = 0
    let availableWidth = max(100, bounds.width)
    // Trailing margin from the previous .text block, applied before the next block.
    var pendingMargin: CGFloat = 0

    for block in blocks {
      switch block {
        case let .text(attrStr):
          yOffset += pendingMargin
          pendingMargin = 0
          let textView = makeTextView(attrStr, width: availableWidth)
          let height = Self.measureTextHeight(attrStr, width: availableWidth)
          textView.frame = CGRect(x: 0, y: yOffset, width: availableWidth, height: height)
          addSubview(textView)
          yOffset += height
          pendingMargin = Self.trailingSpacing(attrStr)

        case let .codeBlock(language, code):
          yOffset += max(pendingMargin, Self.codeBlockVerticalMargin)
          pendingMargin = 0
          let codeView = NativeCodeBlockView(frame: CGRect(
            x: 0, y: yOffset, width: availableWidth,
            height: NativeCodeBlockView.requiredHeight(
              lineCount: code.components(separatedBy: "\n").count,
              isExpanded: false
            )
          ))
          codeView.configure(language: language, code: code)
          addSubview(codeView)
          yOffset += codeView.frame.height
          yOffset += Self.codeBlockVerticalMargin

        case let .blockquote(attrStr):
          yOffset += max(pendingMargin, Self.blockquoteVerticalMargin)
          pendingMargin = 0
          let quoteHeight = Self.measureTextHeight(
            attrStr,
            width: availableWidth - Self.blockquoteLeadingPad - Self.blockquoteBarWidth - 4
          )

          // Accent bar
          let bar = PlatformView(frame: CGRect(x: 0, y: yOffset, width: Self.blockquoteBarWidth, height: quoteHeight))
          #if os(macOS)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = Self.blockquoteBarColor.cgColor
            bar.layer?.cornerRadius = 1.5
          #else
            bar.backgroundColor = Self.blockquoteBarColor
            bar.layer.cornerRadius = 1.5
          #endif
          addSubview(bar)

          // Quote text
          let textView = makeTextView(
            attrStr,
            width: availableWidth - Self.blockquoteLeadingPad - Self.blockquoteBarWidth
          )
          textView.frame = CGRect(
            x: Self.blockquoteBarWidth + Self.blockquoteLeadingPad,
            y: yOffset,
            width: availableWidth - Self.blockquoteBarWidth - Self.blockquoteLeadingPad,
            height: quoteHeight
          )
          addSubview(textView)
          yOffset += quoteHeight
          yOffset += Self.blockquoteVerticalMargin

        case let .table(headers, rows):
          yOffset += max(pendingMargin, Self.tableVerticalMargin)
          pendingMargin = 0
          let tableHeight = NativeMarkdownTableView.requiredHeight(headerCount: headers.count, rowCount: rows.count)
          let tableView = NativeMarkdownTableView(frame: CGRect(
            x: 0,
            y: yOffset,
            width: availableWidth,
            height: tableHeight
          ))
          tableView.configure(headers: headers, rows: rows)
          addSubview(tableView)
          yOffset += tableHeight
          yOffset += Self.tableVerticalMargin

        case .thematicBreak:
          yOffset += max(pendingMargin, 14)
          pendingMargin = 0
          let dotsView = ThematicBreakView(frame: CGRect(x: 0, y: yOffset, width: availableWidth, height: 4))
          addSubview(dotsView)
          yOffset += 4
          yOffset += 14
      }
    }

    frame.size.height = yOffset
  }

  // MARK: - Height Calculation (Deterministic)

  /// Calculate the required height for the given blocks at the specified width.
  /// Uses NSLayoutManager for text measurement — fully deterministic.
  static func requiredHeight(for blocks: [MarkdownBlock], width: CGFloat) -> CGFloat {
    guard width > 1 else { return 1 }
    var totalHeight: CGFloat = 0
    var pendingMargin: CGFloat = 0

    for block in blocks {
      switch block {
        case let .text(attrStr):
          totalHeight += pendingMargin
          pendingMargin = 0
          totalHeight += measureTextHeight(attrStr, width: width)
          pendingMargin = trailingSpacing(attrStr)

        case let .codeBlock(_, code):
          totalHeight += max(pendingMargin, codeBlockVerticalMargin)
          pendingMargin = 0
          totalHeight += NativeCodeBlockView.requiredHeight(
            lineCount: code.components(separatedBy: "\n").count,
            isExpanded: false
          )
          totalHeight += codeBlockVerticalMargin

        case let .blockquote(attrStr):
          totalHeight += max(pendingMargin, blockquoteVerticalMargin)
          pendingMargin = 0
          totalHeight += measureTextHeight(
            attrStr,
            width: width - blockquoteLeadingPad - blockquoteBarWidth - 4
          )
          totalHeight += blockquoteVerticalMargin

        case let .table(headers, rows):
          totalHeight += max(pendingMargin, tableVerticalMargin)
          pendingMargin = 0
          totalHeight += NativeMarkdownTableView.requiredHeight(headerCount: headers.count, rowCount: rows.count)
          totalHeight += tableVerticalMargin

        case .thematicBreak:
          totalHeight += max(pendingMargin, 14)
          pendingMargin = 0
          totalHeight += 4 + 14
      }
    }

    return ceil(totalHeight)
  }

  // MARK: - Text Measurement

  /// Deterministic text height measurement using NSTextStorage + NSLayoutManager (TextKit 1).
  static func measureTextHeight(_ attrStr: NSAttributedString, width: CGFloat) -> CGFloat {
    guard attrStr.length > 0, width > 1 else { return 0 }

    let textStorage = NSTextStorage(attributedString: attrStr)
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    textContainer.lineFragmentPadding = 0

    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)

    // Force glyph generation + layout
    layoutManager.ensureLayout(for: textContainer)
    let usedRect = layoutManager.usedRect(for: textContainer)

    return ceil(usedRect.height)
  }

  // MARK: - View Factory

  #if os(macOS)
    private func makeTextView(_ attrStr: NSAttributedString, width: CGFloat) -> NSTextView {
      let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 0))
      textView.drawsBackground = false
      textView.isEditable = false
      textView.isSelectable = true
      textView.textContainerInset = .zero
      textView.textContainer?.lineFragmentPadding = 0
      textView.textContainer?.widthTracksTextView = true
      textView.isVerticallyResizable = false
      textView.isHorizontallyResizable = false
      textView.textStorage?.setAttributedString(attrStr)
      // Enable link clicking
      textView.isAutomaticLinkDetectionEnabled = false
      textView.linkTextAttributes = [
        .foregroundColor: PlatformColor.calibrated(red: 0.5, green: 0.72, blue: 0.95, alpha: 1),
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .cursor: NSCursor.pointingHand,
      ]
      return textView
    }
  #else
    private func makeTextView(_ attrStr: NSAttributedString, width: CGFloat) -> UITextView {
      let textView = UITextView(frame: CGRect(x: 0, y: 0, width: width, height: 0))
      textView.backgroundColor = .clear
      textView.isEditable = false
      textView.isSelectable = true
      textView.isScrollEnabled = false
      textView.textContainerInset = .zero
      textView.textContainer.lineFragmentPadding = 0
      textView.attributedText = attrStr
      textView.linkTextAttributes = [
        .foregroundColor: PlatformColor.calibrated(red: 0.5, green: 0.72, blue: 0.95, alpha: 1),
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ]
      return textView
    }
  #endif
}

// MARK: - Thematic Break View (three dots)

private final class ThematicBreakView: PlatformView {
  #if os(macOS)
    override var isFlipped: Bool {
      true
    }
  #endif

  override func draw(_ rect: CGRect) {
    super.draw(rect)

    #if os(macOS)
      guard let context = NSGraphicsContext.current?.cgContext else { return }
    #else
      guard let context = UIGraphicsGetCurrentContext() else { return }
    #endif

    #if os(macOS)
      let dotColor = PlatformColor.secondaryLabelColor.withAlphaComponent(0.4)
    #else
      let dotColor = PlatformColor.secondaryLabel.withAlphaComponent(0.4)
    #endif
    context.setFillColor(dotColor.cgColor)

    let dotSize: CGFloat = 4
    let spacing: CGFloat = 8
    let totalWidth = dotSize * 3 + spacing * 2
    let startX = (bounds.width - totalWidth) / 2
    let y = (bounds.height - dotSize) / 2

    for i in 0 ..< 3 {
      let x = startX + CGFloat(i) * (dotSize + spacing)
      context.fillEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
    }
  }
}
