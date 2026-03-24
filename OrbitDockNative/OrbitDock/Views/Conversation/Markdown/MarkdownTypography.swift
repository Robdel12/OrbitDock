//
//  MarkdownTypography.swift
//  OrbitDock
//
//  Design system for markdown text rendering.
//  Encodes heading hierarchy, body line spacing, inline code styling,
//  and contextual spacing between block-level elements.
//
//  Font mapping (all via SF system fonts):
//    Body  → SF Pro Text (auto at < 20pt)
//    H1/H2 → SF Pro Display (auto at >= 20pt via optical size axis)
//    Code  → SF Mono (via .monospaced design)
//

import SwiftUI

enum MarkdownTypography {

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Heading

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static func headingFont(level: Int, style: ContentStyle) -> Font {
    .system(size: headingSize(level: level, style: style), weight: headingWeight(level: level))
  }

  static func headingSize(level: Int, style: ContentStyle) -> CGFloat {
    switch style {
      case .standard:
        switch level {
          case 1: TypeScale.chatHeading1 // 22pt — rare, major sections
          case 2: TypeScale.chatHeading2 // 18pt — primary structure ("Part 1: ...")
          case 3: TypeScale.chatHeading3 // 16pt — sub-sections
          default: TypeScale.chatBody // 15pt — h4+ treated as emphasized body
        }
      case .thinking:
        switch level {
          case 1: TypeScale.thinkingHeading1 // 18pt
          case 2: TypeScale.thinkingHeading2 // 16pt
          default: TypeScale.code // 13pt
        }
    }
  }

  static func headingWeight(level: Int) -> Font.Weight {
    switch level {
      case 1: .bold
      case 2: .semibold
      case 3: .semibold
      default: .medium
    }
  }

  static func headingColor(level: Int) -> Color {
    switch level {
      case 1, 2: .textPrimary
      case 3: .textSecondary
      default: .textSecondary
    }
  }

  /// Extra bottom spacing after a heading, keeping it tightly coupled to its content.
  static func headingBottomPadding(level: Int, style: ContentStyle) -> CGFloat {
    style == .thinking ? 2 : 4
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Body

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static func bodyFont(style: ContentStyle) -> Font {
    .system(size: bodySize(style: style))
  }

  static func bodyForegroundColor(style: ContentStyle) -> Color {
    switch style {
      case .standard:
        .textPrimary
      case .thinking:
        .textSecondary
    }
  }

  static func bodySize(style: ContentStyle) -> CGFloat {
    switch style {
      case .standard: TypeScale.chatBody // 15pt
      case .thinking: TypeScale.code // 13pt
    }
  }

  /// Extra line spacing for multi-line prose. Added on top of the font's
  /// built-in leading to reach ~1.47x effective line height (22pt for 15pt text).
  static func bodyLineSpacing(style: ContentStyle) -> CGFloat {
    switch style {
      case .standard: 4
      case .thinking: 3
    }
  }

  static func paragraphSpacing(style: ContentStyle) -> String {
    style == .thinking ? "\n" : "\n\n"
  }

  static func listContinuationSpacing(style: ContentStyle) -> String {
    "\n"
  }

  static func listChildSpacing(style: ContentStyle) -> String {
    "\n"
  }

  static func blockquoteForegroundColor(style: ContentStyle) -> Color {
    style == .standard ? .textSecondary : .textTertiary
  }

  static func blockquotePrefixColor(style: ContentStyle) -> Color {
    style == .standard ? .textQuaternary : .textQuaternary
  }

  static func blockquotePrefix(style: ContentStyle) -> String {
    "▎ "
  }

  static func listIndentString(depth: Int) -> String {
    String(repeating: "\u{00A0}\u{00A0}", count: depth + 1)
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Inline Code

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Warm signal orange for inline code spans (backtick-wrapped text).
  static let inlineCodeColor = Color.markdownInlineCode

  static func inlineCodeSize(style: ContentStyle) -> CGFloat {
    switch style {
      case .standard: TypeScale.chatCode // 14pt
      case .thinking: TypeScale.code // 13pt
    }
  }

  /// Post-processes a SwiftUI `AttributedString` to style inline code spans
  /// with monospaced font and the warm signal color.
  static func applyInlineCodeStyle(
    _ source: AttributedString,
    style: ContentStyle
  ) -> AttributedString {
    var result = source
    let codeRanges = result.runs.compactMap { run -> Range<AttributedString.Index>? in
      guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { return nil }
      return run.range
    }
    let size = inlineCodeSize(style: style)
    for range in codeRanges {
      result[range].foregroundColor = inlineCodeColor
      result[range].font = .system(size: size, weight: .medium, design: .monospaced)
    }
    return result
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: List

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Per-level indentation for nested list items.
  static func listIndent(style: ContentStyle) -> CGFloat {
    style == .thinking ? 16 : 20
  }

  /// Vertical spacing between sibling list items.
  static func listItemSpacing(style: ContentStyle) -> CGFloat {
    style == .thinking ? 4 : 6
  }

  /// Horizontal gap between the marker and the item content.
  static func listMarkerGap(style: ContentStyle) -> CGFloat {
    style == .thinking ? 4 : 6
  }

  /// Marker color per marker type — dimmed relative to body text.
  static func listMarkerColor(_ marker: ListMarker) -> Color {
    switch marker {
      case .bullet, .number: .textSecondary
      case .checked: .accent
      case .unchecked: .textTertiary
    }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Inter-Block Spacing

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Contextual vertical gap between two adjacent markdown blocks.
  /// Headings pull extra space above to separate sections, then couple
  /// tightly to whatever follows them.
  static func interBlockSpacing(
    previous: MarkdownBlock?,
    current: MarkdownBlock,
    style: ContentStyle
  ) -> CGFloat {
    // First block: no top spacing
    guard let previous else { return 0 }

    let base: CGFloat = style == .thinking ? 8 : 12

    switch (previous, current) {
      // Heading after anything → extra top space to separate sections
      case let (_, .heading(level, _)):
        switch style {
          case .standard:
            switch level {
              case 1: return 24
              case 2: return 20
              case 3: return 16
              default: return base
            }
          case .thinking:
            switch level {
              case 1: return 16
              case 2: return 12
              default: return 8
            }
        }

      // Content right after a heading → tight coupling
      case (.heading, _):
        return style == .thinking ? 4 : 6

      // Thematic breaks get extra breathing room
      case (_, .thematicBreak), (.thematicBreak, _):
        return style == .thinking ? 8 : 16

      default:
        return base
    }
  }
}
