//
//  MarkdownTypes.swift
//  OrbitDock
//
//  Shared markdown block model + style enum.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

enum MarkdownBlock: Equatable {
  case text(NSAttributedString)
  case codeBlock(language: String?, code: String)
  case blockquote(NSAttributedString)
  case table(headers: [String], rows: [[String]])
  case thematicBreak

  static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
    switch (lhs, rhs) {
      case let (.text(a), .text(b)):
        a.isEqual(to: b)
      case let (.codeBlock(la, ca), .codeBlock(lb, cb)):
        la == lb && ca == cb
      case let (.blockquote(a), .blockquote(b)):
        a.isEqual(to: b)
      case let (.table(ha, ra), .table(hb, rb)):
        ha == hb && ra == rb
      case (.thematicBreak, .thematicBreak):
        true
      default:
        false
    }
  }
}

enum ContentStyle: Hashable {
  case standard
  case thinking
}

enum MarkdownLayoutMetrics {
  enum BlockKind {
    case codeBlock
    case table
    case blockquote
    case thematicBreak
  }

  static func minimumTextBlockSpacing(style: ContentStyle) -> CGFloat {
    switch style {
      case .standard: 4
      case .thinking: 3
    }
  }

  static func trailingTextBlockSpacing(_ attrStr: NSAttributedString, style: ContentStyle) -> CGFloat {
    guard attrStr.length > 0 else { return 0 }
    if let paragraphStyle = attrStr.attribute(.paragraphStyle, at: attrStr.length - 1, effectiveRange: nil) as? NSParagraphStyle
    {
      return max(minimumTextBlockSpacing(style: style), paragraphStyle.paragraphSpacing)
    }
    return minimumTextBlockSpacing(style: style)
  }

  static func verticalMargin(for block: BlockKind, style: ContentStyle) -> CGFloat {
    switch (block, style) {
      case (.codeBlock, .standard), (.table, .standard), (.blockquote, .standard): 8
      case (.codeBlock, .thinking), (.table, .thinking), (.blockquote, .thinking): 6
      case (.thematicBreak, .standard): 14
      case (.thematicBreak, .thinking): 8
    }
  }

  static func blockquoteBarWidth(style: ContentStyle) -> CGFloat {
    switch style {
      case .standard: 3
      case .thinking: 2
    }
  }

  static func blockquoteLeadingPadding(style: ContentStyle) -> CGFloat {
    switch style {
      case .standard: 14
      case .thinking: 10
    }
  }
}
