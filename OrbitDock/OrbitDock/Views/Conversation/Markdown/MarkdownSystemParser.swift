//
//  MarkdownSystemParser.swift
//  OrbitDock
//
//  Single markdown parsing adapter used by native timeline and SwiftUI surfaces.
//  Uses Apple's markdown attributed-string parser for inline semantics and
//  swift-markdown for block structure extraction.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import Foundation
import Markdown
import SwiftUI

enum MarkdownSystemParser {
  private struct ParseCacheKey: Hashable {
    let markdown: String
    let style: ContentStyle
  }

  private struct ParseCacheEntry {
    let blocks: [MarkdownBlock]
    var accessTick: UInt64
  }

  private static var parseCache: [ParseCacheKey: ParseCacheEntry] = [:]
  private static var parseCacheTick: UInt64 = 0
  #if os(iOS)
    private static let maxCacheSize = 160
  #else
    private static let maxCacheSize = 500
  #endif
  private static let evictionBatchSize = 64

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: - Typography Rhythm System
  //
  // All spacing values sit on a **4pt baseline grid** (see Spacing in Theme.swift).
  //
  // Font sizes (from TypeScale):
  //   Standard body: 15pt  (chatBody)       Thinking body: 13pt  (code)
  //   Standard code: 14pt  (chatCode)       Thinking code: 12pt  (caption)
  //   Standard H1-H3: 24→20→16             Thinking H1-H3: 18→16→14
  //   Standard H4-H6: 15→14→13             Thinking H4-H6: 13→12→12
  //
  // Line spacing (NSParagraphStyle.lineSpacing — additive to natural line height):
  //   Standard: +6pt → ~24pt total at 15pt body (1.6× effective line height)
  //   Thinking: +4pt → ~20pt total at 13pt body (1.54×)
  //
  // Paragraph spacing (gap between paragraphs within a text block):
  //   Body: 16pt standard / 12pt thinking
  //   List items: 8pt / 4pt; continuation paragraphs tighter (4pt / 2pt)
  //   Blockquotes: 12pt / 8pt
  //
  // Heading spacing (paragraphSpacingBefore / paragraphSpacing):
  //   Top spacing creates "section break" feel (1.5–2× body paragraphSpacing).
  //   Bottom spacing ties heading to its content (0.25–0.75× body paragraphSpacing).
  //   Standard: H1=28/12  H2=24/8  H3=20/8  H4=16/8  H5=12/4  H6=8/4
  //   Thinking: H1=16/8   H2=12/4  H3=8/4   H4=8/4   H5=4/4   H6=4/4
  //
  // Inter-block spacing (MarkdownLayoutMetrics in MarkdownTypes.swift):
  //   Code/table/blockquote: 12pt standard / 8pt thinking — symmetric above and below.
  //   Thematic break: 16pt / 8pt.
  //   Text-to-text: uses trailing paragraphSpacing from last paragraph (min 4pt/3pt).
  //
  // Design constraints:
  //   - Body font (15pt) and code font (14pt mono) are anchor points — do not change.
  //   - Content caps at 880pt wide (ConversationLayout.assistantRailMaxWidth).
  //   - Thinking mode should be noticeably compact, not just smaller.
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  private enum Typography {
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

  enum TextRole {
    case body
    case blockquote
  }

  static func parse(_ markdown: String, style: ContentStyle = .standard) -> [MarkdownBlock] {
    let key = ParseCacheKey(markdown: markdown, style: style)
    if var cached = parseCache[key] {
      cached.accessTick = nextParseCacheTick()
      parseCache[key] = cached
      return cached.blocks
    }

    let blocks = parseUncached(markdown, style: style)
    insertCacheValue(blocks, for: key)
    return blocks
  }

  static func clearCache() {
    parseCache.removeAll(keepingCapacity: true)
    parseCacheTick = 0
  }

  private static func parseUncached(_ markdown: String, style: ContentStyle) -> [MarkdownBlock] {
    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

    let document = Document(parsing: markdown)
    var blocks: [MarkdownBlock] = []

    for child in document.children {
      appendBlock(from: child, style: style, into: &blocks)
    }

    return blocks
  }

  private static func nextParseCacheTick() -> UInt64 {
    parseCacheTick &+= 1
    return parseCacheTick
  }

  private static func insertCacheValue(_ value: [MarkdownBlock], for key: ParseCacheKey) {
    if parseCache[key] == nil {
      evictIfNeeded()
    }

    parseCache[key] = ParseCacheEntry(blocks: value, accessTick: nextParseCacheTick())
  }

  private static func evictIfNeeded() {
    guard parseCache.count >= maxCacheSize else { return }
    let toEvict = min(evictionBatchSize, parseCache.count)
    guard toEvict > 0 else { return }

    let keysToEvict = parseCache
      .sorted { lhs, rhs in
        lhs.value.accessTick < rhs.value.accessTick
      }
      .prefix(toEvict)
      .map(\.key)
    for key in keysToEvict {
      parseCache.removeValue(forKey: key)
    }
  }

  private static func appendBlock(from markup: any Markup, style: ContentStyle, into blocks: inout [MarkdownBlock]) {
    switch markup {
      case let codeBlock as CodeBlock:
        var code = codeBlock.code
        while code.hasSuffix("\n") {
          code = String(code.dropLast())
        }
        blocks.append(.codeBlock(language: MarkdownLanguage.normalize(codeBlock.language), code: code))

      case let table as Markdown.Table:
        blocks.append(tableBlock(from: table))

      case is ThematicBreak:
        blocks.append(.thematicBreak)

      case let blockQuote as BlockQuote:
        let attributed = styledBlockquoteText(from: blockQuote, style: style)
        if attributed.length > 0 {
          blocks.append(.blockquote(attributed))
        }

      case let paragraph as Paragraph:
        let attributed = styledText(from: markdownSource(for: paragraph), style: style, role: .body)
        if attributed.length > 0 {
          blocks.append(.text(attributed))
        }

      case let heading as Heading:
        let attributed = styledText(from: markdownSource(for: heading), style: style, role: .body)
        if attributed.length > 0 {
          blocks.append(.text(attributed))
        }

      case let orderedList as OrderedList:
        let attributed = styledListMarkup(for: orderedList, style: style, role: .body)
        if attributed.length > 0 {
          blocks.append(.text(attributed))
        }

      case let unorderedList as UnorderedList:
        let attributed = styledListMarkup(for: unorderedList, style: style, role: .body)
        if attributed.length > 0 {
          blocks.append(.text(attributed))
        }

      case let htmlBlock as HTMLBlock:
        let attributed = styledText(from: htmlBlock.rawHTML, style: style, role: .body)
        if attributed.length > 0 {
          blocks.append(.text(attributed))
        }

      default:
        for child in markup.children {
          appendBlock(from: child, style: style, into: &blocks)
        }
    }
  }

  private static func tableBlock(from table: Markdown.Table) -> MarkdownBlock {
    let headers = Array(table.head.cells).map { cell in
      tableCellSource(cell)
    }

    let rows = Array(table.body.rows).map { row in
      let values = Array(row.cells).map { cell in
        tableCellSource(cell)
      }
      let padded = values + Array(repeating: "", count: max(0, headers.count - values.count))
      return Array(padded.prefix(headers.count))
    }

    return .table(headers: headers, rows: rows)
  }

  private static func tableCellSource(_ cell: Markdown.Table.Cell) -> String {
    // `Markup.format()` traps for `Table.Cell` in swift-markdown (it does not support
    // direct formatting of table-cell nodes), so serialize child markup instead.
    let source = cell.children
      .map { markdownSource(for: $0) }
      .joined(separator: "\n")
    return source.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func inlineTableCellText(
    from markdown: String,
    style: ContentStyle,
    isHeader: Bool
  ) -> NSAttributedString {
    let normalized = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return NSAttributedString(string: "") }

    let parsed: AttributedString
    do {
      parsed = try AttributedString(
        markdown: normalized,
        options: .init(interpretedSyntax: .inlineOnly)
      )
    } catch {
      return NSAttributedString(string: normalized, attributes: [
        .font: tableCellFont(style: style, isHeader: isHeader),
        .foregroundColor: PlatformColor(style == .thinking ? Color.textSecondary : Color.textPrimary),
      ])
    }

    let ns = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
    let fullRange = NSRange(location: 0, length: ns.length)
    guard fullRange.length > 0 else { return ns }

    let baseFont = tableCellFont(style: style, isHeader: isHeader)
    let baseColor = PlatformColor(style == .thinking ? Color.textSecondary : Color.textPrimary)
    let linkColor = PlatformColor(Color.markdownLink)
    let inlineCodeColor = PlatformColor(Color.markdownInlineCode).withAlphaComponent(style == .thinking ? 0.85 : 1)
    let inlineCodeBackground = PlatformColor.white.withAlphaComponent(style == .thinking ? 0.05 : 0.08)

    ns.addAttribute(.font, value: baseFont, range: fullRange)
    ns.addAttribute(.foregroundColor, value: baseColor, range: fullRange)

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = style == .thinking ? 2 : 3
    paragraph.paragraphSpacing = 0
    paragraph.paragraphSpacingBefore = 0
    ns.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

    var utf16Offset = 0
    for run in parsed.runs {
      let runText = String(parsed[run.range].characters)
      let runLength = runText.utf16.count
      guard runLength > 0 else { continue }
      defer { utf16Offset += runLength }
      guard utf16Offset + runLength <= ns.length else { continue }
      let runRange = NSRange(location: utf16Offset, length: runLength)

      if run.link != nil {
        ns.addAttribute(.foregroundColor, value: linkColor, range: runRange)
        ns.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: runRange)
      }

      if let inlineIntent = run.inlinePresentationIntent {
        if inlineIntent.contains(.code) {
          ns.addAttribute(.font, value: tableInlineCodeFont(style: style), range: runRange)
          ns.addAttribute(.foregroundColor, value: inlineCodeColor, range: runRange)
          ns.addAttribute(.backgroundColor, value: inlineCodeBackground, range: runRange)
        } else {
          let currentFont = (ns.attribute(.font, at: runRange.location, effectiveRange: nil) as? PlatformFont)
            ?? tableCellFont(style: style, isHeader: isHeader)
          if inlineIntent.contains(.stronglyEmphasized), inlineIntent.contains(.emphasized) {
            ns.addAttribute(.font, value: currentFont.withBoldItalic(), range: runRange)
          } else if inlineIntent.contains(.stronglyEmphasized) {
            ns.addAttribute(
              .font,
              value: PlatformFont.systemFont(ofSize: currentFont.pointSize, weight: .bold),
              range: runRange
            )
          } else if inlineIntent.contains(.emphasized) {
            ns.addAttribute(.font, value: currentFont.withItalic(), range: runRange)
          }
        }

        if inlineIntent.contains(.strikethrough) {
          ns.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: runRange)
        }
      }
    }

    return ns
  }

  private static func styledText(
    from markdown: String,
    style: ContentStyle,
    role: TextRole,
    interpretedSyntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax = .full
  ) -> NSAttributedString {
    let normalized = markdown.trimmingCharacters(in: .newlines)
    guard !normalized.isEmpty else { return NSAttributedString(string: "") }

    let parsed: AttributedString
    do {
      parsed = try AttributedString(
        markdown: normalized,
        options: .init(interpretedSyntax: interpretedSyntax)
      )
    } catch {
      return fallbackText(normalized, style: style, role: role)
    }

    let baseColor = role == .blockquote
      ? PlatformColor(Color.textSecondary).withAlphaComponent(style == .thinking ? 0.8 : 0.9)
      : PlatformColor(style == .thinking ? Color.textSecondary : Color.textPrimary)
    let linkColor = PlatformColor(Color.markdownLink)
    let inlineCodeColor = PlatformColor(Color.markdownInlineCode).withAlphaComponent(style == .thinking ? 0.85 : 1)
    let inlineCodeBackground = PlatformColor.white.withAlphaComponent(style == .thinking ? 0.06 : 0.09)

    let ns = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
    let fullRange = NSRange(location: 0, length: ns.length)
    guard fullRange.length > 0 else { return ns }

    ns.addAttribute(.font, value: bodyFont(style: style), range: fullRange)
    ns.addAttribute(.foregroundColor, value: baseColor, range: fullRange)
    applyRhythm(to: ns, in: fullRange, style: style, role: role)

    var utf16Offset = 0
    for run in parsed.runs {
      let runText = String(parsed[run.range].characters)
      let length = runText.utf16.count
      guard length > 0 else { continue }
      defer { utf16Offset += length }

      guard utf16Offset + length <= ns.length else { continue }
      let nsRange = NSRange(location: utf16Offset, length: length)

      if run.link != nil {
        ns.addAttribute(.foregroundColor, value: linkColor, range: nsRange)
        ns.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: nsRange)
      }

      if let inlineIntent = run.inlinePresentationIntent {
        if inlineIntent.contains(.code) {
          ns.addAttribute(.font, value: inlineCodeFont(style: style), range: nsRange)
          ns.addAttribute(.foregroundColor, value: inlineCodeColor, range: nsRange)
          ns.addAttribute(.backgroundColor, value: inlineCodeBackground, range: nsRange)
        } else {
          let currentFont = (ns.attribute(.font, at: nsRange.location, effectiveRange: nil) as? PlatformFont)
            ?? bodyFont(style: style)
          if inlineIntent.contains(.stronglyEmphasized), inlineIntent.contains(.emphasized) {
            ns.addAttribute(.font, value: currentFont.withBoldItalic(), range: nsRange)
          } else if inlineIntent.contains(.stronglyEmphasized) {
            ns.addAttribute(
              .font,
              value: PlatformFont.systemFont(ofSize: currentFont.pointSize, weight: .bold),
              range: nsRange
            )
          } else if inlineIntent.contains(.emphasized) {
            ns.addAttribute(.font, value: currentFont.withItalic(), range: nsRange)
          }
        }

        if inlineIntent.contains(.strikethrough) {
          ns.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: nsRange)
        }
      }

      if let headingLevel = headingLevel(from: run.presentationIntent) {
        let level = min(max(headingLevel, 1), 6)
        ns.addAttribute(.font, value: headingFont(level: level, style: style), range: nsRange)
        ns.addAttribute(.foregroundColor, value: headingColor(level: level, style: style), range: nsRange)

        let headingStyle = mergedParagraphStyle(
          in: ns,
          at: nsRange.location,
          style: style,
          role: role
        )
        headingStyle.paragraphSpacingBefore = headingTopSpacing(level: level, style: style)
        headingStyle.paragraphSpacing = headingBottomSpacing(level: level, style: style)
        ns.addAttribute(.paragraphStyle, value: headingStyle, range: nsRange)
      }
    }

    trimTrailingNewlines(in: ns)
    return ns
  }

  private static func styledListText(
    from markdown: String,
    style: ContentStyle,
    role: TextRole = .body
  ) -> NSAttributedString {
    let attributed = styledText(
      from: markdown,
      style: style,
      role: role,
      interpretedSyntax: .inlineOnly
    )
    let mutable = NSMutableAttributedString(attributedString: attributed)
    let fullRange = NSRange(location: 0, length: mutable.length)
    if fullRange.length > 0 {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = Typography.lineSpacing(for: .list, style: style)
      paragraph.paragraphSpacing = Typography.paragraphSpacing(for: .list, style: style)
      mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
      applyListParagraphIndents(to: mutable, style: style)
    }
    return mutable
  }

  private static func styledListMarkup(
    for listMarkup: any Markup,
    style: ContentStyle,
    role: TextRole
  ) -> NSAttributedString {
    let markdown = markdownSource(for: listMarkup)
    let normalized = normalizeListDisplaySource(markdown)
    return styledListText(from: normalized, style: style, role: role)
  }

  private static func styledBlockquoteText(from blockQuote: BlockQuote, style: ContentStyle) -> NSAttributedString {
    let mutable = NSMutableAttributedString()
    let separator = NSAttributedString(string: "\n")
    var didAppendContent = false

    for child in blockQuote.children {
      let childAttributed = styledBlockquoteChild(child, style: style)
      guard childAttributed.length > 0 else { continue }

      if didAppendContent {
        mutable.append(separator)
      }
      mutable.append(childAttributed)
      didAppendContent = true
    }

    if mutable.length > 0 {
      applyListParagraphIndents(to: mutable, style: style)
      trimTrailingNewlines(in: mutable)
    }
    return mutable
  }

  private static func styledBlockquoteChild(_ child: any Markup, style: ContentStyle) -> NSAttributedString {
    switch child {
      case let paragraph as Paragraph:
        return styledText(from: markdownSource(for: paragraph), style: style, role: .blockquote)

      case let heading as Heading:
        return styledText(from: markdownSource(for: heading), style: style, role: .blockquote)

      case let orderedList as OrderedList:
        return styledListMarkup(for: orderedList, style: style, role: .blockquote)

      case let unorderedList as UnorderedList:
        return styledListMarkup(for: unorderedList, style: style, role: .blockquote)

      case let nestedQuote as BlockQuote:
        return styledBlockquoteText(from: nestedQuote, style: style)

      case let codeBlock as CodeBlock:
        var code = codeBlock.code
        while code.hasSuffix("\n") {
          code = String(code.dropLast())
        }
        return styledText(from: code, style: style, role: .blockquote, interpretedSyntax: .inlineOnly)

      default:
        return styledText(from: markdownSource(for: child), style: style, role: .blockquote)
    }
  }

  private static func fallbackText(_ text: String, style: ContentStyle, role: TextRole) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    let kind: Typography.BlockKind = role == .blockquote ? .blockquote : .body
    paragraph.lineSpacing = Typography.lineSpacing(for: kind, style: style)
    paragraph.paragraphSpacing = Typography.paragraphSpacing(for: kind, style: style)
    let color = role == .blockquote
      ? PlatformColor(Color.textSecondary).withAlphaComponent(style == .thinking ? 0.8 : 0.9)
      : PlatformColor(style == .thinking ? Color.textSecondary : Color.textPrimary)
    return NSAttributedString(string: text, attributes: [
      .font: bodyFont(style: style),
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ])
  }

  private static func applyRhythm(
    to attributed: NSMutableAttributedString,
    in fullRange: NSRange,
    style: ContentStyle,
    role: TextRole
  ) {
    attributed.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
      let paragraph = mergedParagraphStyle(
        from: value as? NSParagraphStyle,
        style: style,
        role: role
      )
      attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
    }
  }

  private static func mergedParagraphStyle(
    in attributed: NSAttributedString,
    at location: Int,
    style: ContentStyle,
    role: TextRole
  ) -> NSMutableParagraphStyle {
    let existing = attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
    return mergedParagraphStyle(from: existing, style: style, role: role)
  }

  private static func mergedParagraphStyle(
    from existing: NSParagraphStyle?,
    style: ContentStyle,
    role: TextRole
  ) -> NSMutableParagraphStyle {
    let paragraph = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
    let kind: Typography.BlockKind = role == .blockquote ? .blockquote : .body
    paragraph.lineSpacing = Typography.lineSpacing(for: kind, style: style)
    let defaultSpacing: CGFloat = Typography.paragraphSpacing(for: kind, style: style)
    paragraph.paragraphSpacing = max(defaultSpacing, paragraph.paragraphSpacing)
    return paragraph
  }

  private static func headingLevel(from intent: PresentationIntent?) -> Int? {
    guard let intent else { return nil }
    for component in intent.components {
      if case let .header(level) = component.kind {
        return level
      }
    }
    return nil
  }

  private static func bodyFont(style: ContentStyle) -> PlatformFont {
    PlatformFont.systemFont(ofSize: style == .thinking ? TypeScale.code : TypeScale.chatBody)
  }

  private static func inlineCodeFont(style: ContentStyle) -> PlatformFont {
    PlatformFont.monospacedSystemFont(
      ofSize: style == .thinking ? TypeScale.caption : TypeScale.chatCode,
      weight: .regular
    )
  }

  private static func tableCellFont(style: ContentStyle, isHeader: Bool) -> PlatformFont {
    let size = style == .thinking ? TypeScale.code : TypeScale.chatBody
    let weight: PlatformFont.Weight = isHeader ? .semibold : .regular
    return PlatformFont.systemFont(ofSize: size, weight: weight)
  }

  private static func tableInlineCodeFont(style: ContentStyle) -> PlatformFont {
    PlatformFont.monospacedSystemFont(
      ofSize: style == .thinking ? TypeScale.caption : TypeScale.code,
      weight: .regular
    )
  }

  private static func headingFont(level: Int, style: ContentStyle) -> PlatformFont {
    let isThinking = style == .thinking
    switch level {
      case 1:
        return PlatformFont.systemFont(ofSize: isThinking ? TypeScale.thinkingHeading1 : TypeScale.chatHeading1, weight: .bold)
      case 2:
        return PlatformFont.systemFont(ofSize: isThinking ? TypeScale.thinkingHeading2 : TypeScale.chatHeading2, weight: .semibold)
      case 3:
        return PlatformFont.systemFont(ofSize: isThinking ? TypeScale.chatCode : TypeScale.chatHeading3, weight: .bold)
      case 4:
        return PlatformFont.systemFont(ofSize: isThinking ? TypeScale.code : TypeScale.chatBody, weight: .semibold)
      case 5:
        return PlatformFont.systemFont(ofSize: isThinking ? TypeScale.caption : TypeScale.chatCode, weight: .semibold)
      default:
        return PlatformFont.systemFont(ofSize: isThinking ? TypeScale.caption : TypeScale.body, weight: .medium)
    }
  }

  private static func headingColor(level: Int, style: ContentStyle) -> PlatformColor {
    let isThinking = style == .thinking
    switch level {
      case 1:
        return PlatformColor(isThinking ? Color.textSecondary : Color.textPrimary)
      case 2:
        return PlatformColor(isThinking ? Color.textSecondary.opacity(0.9) : Color.textPrimary.opacity(0.95))
      case 3:
        return PlatformColor(isThinking ? Color.textSecondary : Color.textPrimary.opacity(0.88))
      case 4:
        return PlatformColor(isThinking ? Color.textSecondary.opacity(0.9) : Color.textPrimary.opacity(0.82))
      case 5:
        return PlatformColor(isThinking ? Color.textSecondary.opacity(0.85) : Color.textSecondary.opacity(0.95))
      default:
        return PlatformColor(isThinking ? Color.textSecondary.opacity(0.8) : Color.textSecondary.opacity(0.9))
    }
  }

  private static func headingTopSpacing(level: Int, style: ContentStyle) -> CGFloat {
    let isThinking = style == .thinking
    switch level {
      case 1: return isThinking ? 16 : 28
      case 2: return isThinking ? 12 : 24
      case 3: return isThinking ? 8 : 20
      case 4: return isThinking ? 8 : 16
      case 5: return isThinking ? 4 : 12
      default: return isThinking ? 4 : 8
    }
  }

  private static func headingBottomSpacing(level: Int, style: ContentStyle) -> CGFloat {
    let isThinking = style == .thinking
    switch level {
      case 1: return isThinking ? 8 : 12
      case 2: return isThinking ? 4 : 8
      case 3: return isThinking ? 4 : 8
      case 4: return isThinking ? 4 : 8
      case 5: return isThinking ? 4 : 4
      default: return isThinking ? 4 : 4
    }
  }

  private static func applyListParagraphIndents(to attributed: NSMutableAttributedString, style: ContentStyle) {
    let markerPattern = #"^(\s*)(?:([•☑☐])|(\d+[.)]))\s+"#
    guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return }

    let nsString = attributed.string as NSString
    let fullRange = NSRange(location: 0, length: nsString.length)

    var previousHeadIndent: CGFloat?

    nsString.enumerateSubstrings(
      in: fullRange,
      options: [.byParagraphs, .substringNotRequired]
    ) { _, paragraphRange, _, _ in
      let line = nsString.substring(with: paragraphRange)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      let lineNS = line as NSString
      let lineRange = NSRange(location: 0, length: lineNS.length)
      let existing = attributed.attribute(
        .paragraphStyle,
        at: paragraphRange.location,
        effectiveRange: nil
      ) as? NSParagraphStyle
      let paragraph = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      var shouldApplyListStyle = false
      var isMarkerLine = false
      let listInset = Typography.listLeadingInset(style: style)

      if trimmed.isEmpty {
        if let previousHeadIndent {
          paragraph.firstLineHeadIndent = previousHeadIndent
          paragraph.headIndent = previousHeadIndent
          paragraph.lineSpacing = Typography.lineSpacing(for: .list, style: style)
          paragraph.paragraphSpacing = Typography.listBlankLineSpacing(style: style)
          paragraph.paragraphSpacingBefore = 0
          attributed.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
        }
        return
      }

      if let match = regex.firstMatch(in: line, options: [], range: lineRange) {
        let markerText = if match.range(at: 2).location != NSNotFound {
          lineNS.substring(with: match.range(at: 2))
        } else {
          lineNS.substring(with: match.range(at: 3))
        }
        let leadingPrefixWidth = leadingIndentWidth(in: line, style: style)
        let markerWidth = max(
          Typography.listMarkerMinWidth,
          markerDisplayWidth(markerText, style: style)
        )

        // Use a hanging indent so marker + content are inset from body text,
        // while wrapped lines align with the marker content start.
        // leadingPrefixWidth accounts for nesting depth so nested items
        // are visually indented further than their parent list items.
        paragraph.firstLineHeadIndent = listInset + leadingPrefixWidth
        paragraph.headIndent = listInset + leadingPrefixWidth + markerWidth
        previousHeadIndent = paragraph.headIndent
        shouldApplyListStyle = true
        isMarkerLine = true
      } else {
        let leadingPrefixWidth = leadingIndentWidth(in: line, style: style)
        if let previousHeadIndent, leadingPrefixWidth > 0 {
          let continuationIndent = max(listInset, previousHeadIndent - leadingPrefixWidth)
          paragraph.firstLineHeadIndent = continuationIndent
          paragraph.headIndent = continuationIndent
          shouldApplyListStyle = true
        } else {
          previousHeadIndent = nil
        }
      }

      guard shouldApplyListStyle else { return }
      paragraph.lineSpacing = Typography.lineSpacing(for: .list, style: style)
      paragraph.paragraphSpacing = isMarkerLine
        ? Typography.paragraphSpacing(for: .list, style: style)
        : Typography.continuationParagraphSpacing(style: style)
      paragraph.paragraphSpacingBefore = 0
      attributed.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
    }
  }

  private static func markerDisplayWidth(_ marker: String, style: ContentStyle) -> CGFloat {
    let font = bodyFont(style: style)
    let measured = (marker + Typography.listMarkerGap) as NSString
    return ceil(measured.size(withAttributes: [.font: font]).width)
  }

  private static func leadingIndentWidth(in line: String, style: ContentStyle) -> CGFloat {
    let leadingPrefix = line.prefix { $0 == " " || $0 == "\t" }
    guard !leadingPrefix.isEmpty else { return 0 }

    var normalizedWhitespace = ""
    normalizedWhitespace.reserveCapacity(leadingPrefix.count * 4)
    for character in leadingPrefix {
      if character == "\t" {
        normalizedWhitespace.append("    ")
      } else {
        normalizedWhitespace.append(" ")
      }
    }

    let font = bodyFont(style: style)
    return ceil((normalizedWhitespace as NSString).size(withAttributes: [.font: font]).width)
  }

  private static func trimTrailingNewlines(in attributed: NSMutableAttributedString) {
    while attributed.string.hasSuffix("\n"), attributed.length > 0 {
      attributed.deleteCharacters(in: NSRange(location: attributed.length - 1, length: 1))
    }
  }

  private static func markdownSource(for markup: any Markup) -> String {
    let detached = markup.detachedFromParent
    return detached.format()
  }

  private static func normalizeListDisplaySource(_ source: String) -> String {
    var normalized = source
    normalized = renumberOrderedListMarkers(in: normalized)
    normalized = normalized.replacingOccurrences(
      of: #"(?m)^(\s*)[-+*]\s+\[(?:x|X)\]\s+"#,
      with: "$1☑\(Typography.listMarkerGap)",
      options: .regularExpression
    )
    normalized = normalized.replacingOccurrences(
      of: #"(?m)^(\s*)[-+*]\s+\[\s\]\s+"#,
      with: "$1☐\(Typography.listMarkerGap)",
      options: .regularExpression
    )
    normalized = normalized.replacingOccurrences(
      of: #"(?m)^(\s*)[-+*]\s+"#,
      with: "$1•\(Typography.listMarkerGap)",
      options: .regularExpression
    )
    normalized = normalized.replacingOccurrences(
      of: #"(?m)^(\s*)(\d+)[.)]\s+"#,
      with: "$1$2.\(Typography.listMarkerGap)",
      options: .regularExpression
    )
    normalized = collapseContinuationBlankLines(in: normalized)
    return normalized
  }

  private static func collapseContinuationBlankLines(in source: String) -> String {
    source.replacingOccurrences(
      of: #"(?m)^(\s*(?:•|☑|☐|\d+\.)\s+.+)\n\n(\s{2,}\S)"#,
      with: "$1\n$2",
      options: .regularExpression
    )
  }

  private static func renumberOrderedListMarkers(in source: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"^(\s*)(\d+)[.)]\s+(.*)$"#) else {
      return source
    }

    let lines = source.components(separatedBy: "\n")
    var countersByIndent: [Int: Int] = [:]
    var renumbered: [String] = []
    renumbered.reserveCapacity(lines.count)

    for line in lines {
      let nsLine = line as NSString
      let lineRange = NSRange(location: 0, length: nsLine.length)
      guard let match = regex.firstMatch(in: line, options: [], range: lineRange) else {
        renumbered.append(line)
        continue
      }

      let indentRange = match.range(at: 1)
      let sourceNumberRange = match.range(at: 2)
      let contentRange = match.range(at: 3)
      guard indentRange.location != NSNotFound,
            sourceNumberRange.location != NSNotFound,
            contentRange.location != NSNotFound
      else {
        renumbered.append(line)
        continue
      }

      let indent = nsLine.substring(with: indentRange)
      let indentLevel = indent.count
      let sourceNumber = Int(nsLine.substring(with: sourceNumberRange)) ?? 1
      let content = nsLine.substring(with: contentRange)

      let keysToRemove = countersByIndent.keys.filter { $0 > indentLevel }
      for key in keysToRemove {
        countersByIndent.removeValue(forKey: key)
      }

      let current = countersByIndent[indentLevel] ?? sourceNumber
      countersByIndent[indentLevel] = current + 1
      renumbered.append("\(indent)\(current). \(content)")
    }

    return renumbered.joined(separator: "\n")
  }
}
