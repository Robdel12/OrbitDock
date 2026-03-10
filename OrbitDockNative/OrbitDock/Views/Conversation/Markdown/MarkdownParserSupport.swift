#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import Foundation

struct MarkdownParseCacheKey: Hashable {
  let markdown: String
  let style: ContentStyle
}

struct MarkdownParseCacheEntry {
  let blocks: [MarkdownBlock]
  var accessTick: UInt64
}

enum MarkdownTypography {
  enum BlockKind {
    case body
    case blockquote
    case list
  }

  static let listMarkerMinWidth: CGFloat = 14
  static let listMarkerGap = "  "

  static func lineSpacing(for kind: BlockKind, style: ContentStyle) -> CGFloat {
    switch (kind, style) {
      case (.body, .standard), (.blockquote, .standard), (.list, .standard): 6
      case (.body, .thinking), (.blockquote, .thinking), (.list, .thinking): 4
    }
  }

  static func paragraphSpacing(for kind: BlockKind, style: ContentStyle) -> CGFloat {
    switch (kind, style) {
      case (.body, .standard): 16
      case (.body, .thinking): 12
      case (.blockquote, .standard): 12
      case (.blockquote, .thinking): 8
      case (.list, .standard): 8
      case (.list, .thinking): 4
    }
  }

  static func continuationParagraphSpacing(style: ContentStyle) -> CGFloat {
    switch style {
      case .standard: 4
      case .thinking: 2
    }
  }

  static func listLeadingInset(style: ContentStyle) -> CGFloat {
    switch style {
      case .standard: 12
      case .thinking: 8
    }
  }

  static func listBlankLineSpacing(style: ContentStyle) -> CGFloat {
    switch style {
      case .standard: 2
      case .thinking: 1
    }
  }
}
