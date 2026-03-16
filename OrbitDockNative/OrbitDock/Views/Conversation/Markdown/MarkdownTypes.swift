//
//  MarkdownTypes.swift
//  OrbitDock
//
//  Shared markdown block model + style enum.
//

import Foundation

enum MarkdownBlock: Equatable {
  case text(String)
  case heading(level: Int, text: String)
  case codeBlock(language: String?, code: String)
  case blockquote(String)
  case table(headers: [String], rows: [[String]])
  case thematicBreak
}

enum ContentStyle: Hashable {
  case standard
  case thinking
}

/// Inter-block spacing metrics for the vertical markdown layout.
///
/// These values control the gap between distinct block-level elements
/// (code blocks, tables, blockquotes, thematic breaks) when laid out
/// by `MarkdownBlockView`. All values sit on a 4pt grid.
enum MarkdownLayoutMetrics {
  enum BlockKind {
    case codeBlock
    case table
    case blockquote
    case thematicBreak
  }

  static func verticalMargin(for block: BlockKind, style: ContentStyle) -> CGFloat {
    switch (block, style) {
      case (.codeBlock, .standard), (.table, .standard), (.blockquote, .standard): 12
      case (.codeBlock, .thinking), (.table, .thinking), (.blockquote, .thinking): 8
      case (.thematicBreak, .standard): 16
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
