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

  private static func blockquoteBarColor(style: ContentStyle) -> PlatformColor {
    switch style {
      case .standard: PlatformColor(Color.accentMuted).withAlphaComponent(0.9)
      case .thinking: PlatformColor(Color.textTertiary).withAlphaComponent(0.5)
    }
  }

  #if os(macOS)
    override var isFlipped: Bool {
      true
    }
  #endif

  // MARK: - State

  private var blocks: [MarkdownBlock] = []
  private var contentStyle: ContentStyle = .standard

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

  func configure(blocks: [MarkdownBlock], style: ContentStyle = .standard) {
    self.blocks = blocks
    contentStyle = style
    rebuildSubviews()
  }

  /// Extract the trailing paragraphSpacing from the last paragraph in an
  /// attributed string. NSLayoutManager ignores this for the final paragraph,
  /// so we apply it as view-level spacing between blocks.
  private static func trailingSpacing(_ attrStr: NSAttributedString, style: ContentStyle) -> CGFloat {
    MarkdownLayoutMetrics.trailingTextBlockSpacing(attrStr, style: style)
  }

  private func rebuildSubviews() {
    subviews.forEach { $0.removeFromSuperview() }
    guard !blocks.isEmpty else { return }

    var yOffset: CGFloat = 0
    let availableWidth = max(100, bounds.width)
    let style = contentStyle
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
          pendingMargin = Self.trailingSpacing(attrStr, style: style)

        case let .codeBlock(language, code):
          let blockMargin = MarkdownLayoutMetrics.verticalMargin(for: .codeBlock, style: style)
          yOffset += max(pendingMargin, blockMargin)
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
          yOffset += blockMargin

        case let .blockquote(attrStr):
          let blockMargin = MarkdownLayoutMetrics.verticalMargin(for: .blockquote, style: style)
          let barWidth = MarkdownLayoutMetrics.blockquoteBarWidth(style: style)
          let leadingPadding = MarkdownLayoutMetrics.blockquoteLeadingPadding(style: style)
          yOffset += max(pendingMargin, blockMargin)
          pendingMargin = 0
          let quoteHeight = Self.measureTextHeight(
            attrStr,
            width: availableWidth - leadingPadding - barWidth - 4
          )

          // Accent bar
          let bar = PlatformView(frame: CGRect(x: 0, y: yOffset, width: barWidth, height: quoteHeight))
          #if os(macOS)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = Self.blockquoteBarColor(style: style).cgColor
            bar.layer?.cornerRadius = 1.5
          #else
            bar.backgroundColor = Self.blockquoteBarColor(style: style)
            bar.layer.cornerRadius = 1.5
          #endif
          addSubview(bar)

          // Quote text
          let textView = makeTextView(
            attrStr,
            width: availableWidth - leadingPadding - barWidth
          )
          textView.frame = CGRect(
            x: barWidth + leadingPadding,
            y: yOffset,
            width: availableWidth - barWidth - leadingPadding,
            height: quoteHeight
          )
          addSubview(textView)
          yOffset += quoteHeight
          yOffset += blockMargin

        case let .table(headers, rows):
          let blockMargin = MarkdownLayoutMetrics.verticalMargin(for: .table, style: style)
          yOffset += max(pendingMargin, blockMargin)
          pendingMargin = 0
          let tableHeight = NativeMarkdownTableView.requiredHeight(
            headers: headers,
            rows: rows,
            width: availableWidth,
            style: style
          )
          let tableView = NativeMarkdownTableView(frame: CGRect(
            x: 0,
            y: yOffset,
            width: availableWidth,
            height: tableHeight
          ))
          tableView.configure(headers: headers, rows: rows, style: style)
          addSubview(tableView)
          yOffset += tableHeight
          yOffset += blockMargin

        case .thematicBreak:
          let breakMargin = MarkdownLayoutMetrics.verticalMargin(for: .thematicBreak, style: style)
          yOffset += max(pendingMargin, breakMargin)
          pendingMargin = 0
          let dotsView = ThematicBreakView(frame: CGRect(x: 0, y: yOffset, width: availableWidth, height: 4))
          addSubview(dotsView)
          yOffset += 4
          yOffset += breakMargin
      }
    }

    frame.size.height = yOffset
  }

  // MARK: - Height Calculation (Deterministic)

  /// Calculate the required height for the given blocks at the specified width.
  /// Uses NSLayoutManager for text measurement — fully deterministic.
  static func requiredHeight(for blocks: [MarkdownBlock], width: CGFloat, style: ContentStyle = .standard) -> CGFloat {
    guard width > 1 else { return 1 }
    var totalHeight: CGFloat = 0
    var pendingMargin: CGFloat = 0

    for block in blocks {
      switch block {
        case let .text(attrStr):
          totalHeight += pendingMargin
          pendingMargin = 0
          totalHeight += measureTextHeight(attrStr, width: width)
          pendingMargin = trailingSpacing(attrStr, style: style)

        case let .codeBlock(_, code):
          let blockMargin = MarkdownLayoutMetrics.verticalMargin(for: .codeBlock, style: style)
          totalHeight += max(pendingMargin, blockMargin)
          pendingMargin = 0
          totalHeight += NativeCodeBlockView.requiredHeight(
            lineCount: code.components(separatedBy: "\n").count,
            isExpanded: false
          )
          totalHeight += blockMargin

        case let .blockquote(attrStr):
          let blockMargin = MarkdownLayoutMetrics.verticalMargin(for: .blockquote, style: style)
          let barWidth = MarkdownLayoutMetrics.blockquoteBarWidth(style: style)
          let leadingPadding = MarkdownLayoutMetrics.blockquoteLeadingPadding(style: style)
          totalHeight += max(pendingMargin, blockMargin)
          pendingMargin = 0
          totalHeight += measureTextHeight(
            attrStr,
            width: width - leadingPadding - barWidth - 4
          )
          totalHeight += blockMargin

        case let .table(headers, rows):
          let blockMargin = MarkdownLayoutMetrics.verticalMargin(for: .table, style: style)
          totalHeight += max(pendingMargin, blockMargin)
          pendingMargin = 0
          totalHeight += NativeMarkdownTableView.requiredHeight(
            headers: headers,
            rows: rows,
            width: width,
            style: style
          )
          totalHeight += blockMargin

        case .thematicBreak:
          let breakMargin = MarkdownLayoutMetrics.verticalMargin(for: .thematicBreak, style: style)
          totalHeight += max(pendingMargin, breakMargin)
          pendingMargin = 0
          totalHeight += 4 + breakMargin
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
      textView.delegate = self
      textView.textStorage?.setAttributedString(attrStr)
      // Enable link clicking
      textView.isAutomaticLinkDetectionEnabled = false
      textView.linkTextAttributes = [
        .foregroundColor: PlatformColor(Color.markdownLink),
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
      textView.delegate = self
      textView.attributedText = attrStr
      textView.linkTextAttributes = [
        .foregroundColor: PlatformColor(Color.markdownLink),
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ]
      return textView
    }
  #endif
}

#if os(macOS)
  extension NativeMarkdownContentView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      let url: URL? = if let value = link as? URL {
        value
      } else if let value = link as? String {
        URL(string: value)
      } else {
        nil
      }

      guard let url else { return false }
      return Platform.services.openURL(url)
    }
  }
#else
  extension NativeMarkdownContentView: UITextViewDelegate {
    func textView(
      _ textView: UITextView,
      primaryActionFor textItem: UITextItem,
      defaultAction: UIAction
    ) -> UIAction? {
      guard case let .link(url) = textItem.content else { return defaultAction }
      return UIAction { _ in
        _ = Platform.services.openURL(url)
      }
    }
  }
#endif

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

    let dotColor = PlatformColor(Color.textQuaternary).withAlphaComponent(0.6)
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
