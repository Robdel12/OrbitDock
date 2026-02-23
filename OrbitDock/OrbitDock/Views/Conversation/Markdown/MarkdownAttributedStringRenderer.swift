//
//  MarkdownAttributedStringRenderer.swift
//  OrbitDock
//
//  Parses markdown via swift-markdown (cmark-gfm) AST and produces
//  [MarkdownBlock] for native rendering. Same public contract as the
//  previous hand-rolled parser — zero downstream changes.
//

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

import Markdown
import SwiftUI

// MARK: - Block Types

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

// MARK: - Content Style

/// Rendering style that controls font sizes and colors.
/// `.thinking` produces smaller, muted text for reasoning blocks.
enum ContentStyle: Hashable {
  case standard
  case thinking
}

// MARK: - Renderer

enum MarkdownAttributedStringRenderer {
  private struct ParseCacheKey: Hashable {
    let markdown: String
    let style: ContentStyle
  }

  /// Parse cache — avoids re-parsing identical content.
  private static var parseCache: [ParseCacheKey: [MarkdownBlock]] = [:]
  #if os(iOS)
    private static let maxCacheSize = 160
  #else
    private static let maxCacheSize = 500
  #endif

  /// Active style context — set during parse, read by Fonts/Colors.
  /// Safe because all rendering is @MainActor.
  private static var activeStyle: ContentStyle = .standard

  /// Parse markdown text into blocks, with caching by content/style key.
  static func parse(_ markdown: String, style: ContentStyle = .standard) -> [MarkdownBlock] {
    let key = ParseCacheKey(markdown: markdown, style: style)
    if let cached = parseCache[key] { return cached }

    activeStyle = style
    let document = Document(parsing: markdown)
    var visitor = MarkdownBlockVisitor()
    let blocks = visitor.visitDocument(document)
    activeStyle = .standard

    if parseCache.count >= maxCacheSize {
      parseCache.removeAll(keepingCapacity: true)
    }
    parseCache[key] = blocks
    return blocks
  }

  /// Clear parse cache (call on memory pressure).
  static func clearCache() {
    parseCache.removeAll(keepingCapacity: true)
  }

  private static let linkDetector: NSDataDetector? = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
  )

  private static let allowedLinkSchemes: Set<String> = [
    "http", "https", "mailto", "tel",
  ]

  private static func isAllowedURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return allowedLinkSchemes.contains(scheme)
  }

  private static func normalizedURL(_ raw: String) -> URL? {
    let trimmed = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    guard !trimmed.isEmpty else { return nil }

    if let url = URL(string: trimmed),
       isAllowedURL(url)
    {
      return url
    }

    if trimmed.contains("://") {
      return nil
    }

    if let https = URL(string: "https://\(trimmed)"),
       isAllowedURL(https)
    {
      return https
    }

    return nil
  }

  // MARK: - Normalize Language

  private static func normalizeLanguage(_ lang: String) -> String {
    switch lang.lowercased() {
      case "js", "jsx": "javascript"
      case "ts", "tsx": "typescript"
      case "sh", "shell", "zsh": "bash"
      case "py": "python"
      case "rb": "ruby"
      case "yml": "yaml"
      case "md": "markdown"
      case "objective-c", "objc": "objectivec"
      default: lang.lowercased()
    }
  }

  /// Body copy leading tuned for dense chat transcripts.
  /// Standard keeps multi-line passages open enough to scan.
  /// Thinking stays compact but avoids cramped 3+ line blocks.
  static var textLineSpacing: CGFloat {
    activeStyle == .thinking ? 5.5 : 7.5
  }

  static var paragraphSpacing: CGFloat {
    activeStyle == .thinking ? 10 : 16
  }

  static var listParagraphSpacingBefore: CGFloat {
    activeStyle == .thinking ? 2 : 4
  }

  static var listParagraphSpacing: CGFloat {
    activeStyle == .thinking ? 4 : 8
  }

  // MARK: - Thinking Font Scale

  private static let thinkingBodySize: CGFloat = 13
  private static let thinkingCodeSize: CGFloat = 11.5

  /// Fonts used for markdown text rendering.
  private enum Fonts {
    // Standard fonts (cached)
    private static let _body = PlatformFont.systemFont(ofSize: TypeScale.chatBody)
    private static let _bodyBold = PlatformFont.systemFont(ofSize: TypeScale.chatBody, weight: .bold)
    private static let _bodyItalic = PlatformFont.systemFont(ofSize: TypeScale.chatBody).withItalic()
    private static let _bodyBoldItalic = PlatformFont
      .systemFont(ofSize: TypeScale.chatBody, weight: .bold).withBoldItalic()

    private static let _inlineCode = PlatformFont.monospacedSystemFont(ofSize: TypeScale.chatCode, weight: .regular)

    // Thinking fonts (cached)
    private static let _thinkingBody = PlatformFont.systemFont(ofSize: thinkingBodySize)
    private static let _thinkingBold = PlatformFont.systemFont(ofSize: thinkingBodySize, weight: .bold)
    private static let _thinkingItalic = PlatformFont.systemFont(ofSize: thinkingBodySize).withItalic()
    private static let _thinkingBoldItalic = PlatformFont
      .systemFont(ofSize: thinkingBodySize, weight: .bold).withBoldItalic()

    private static let _thinkingCode = PlatformFont.monospacedSystemFont(ofSize: thinkingCodeSize, weight: .regular)

    static var body: PlatformFont {
      activeStyle == .thinking ? _thinkingBody : _body
    }

    static var bodyBold: PlatformFont {
      activeStyle == .thinking ? _thinkingBold : _bodyBold
    }

    static var bodyItalic: PlatformFont {
      activeStyle == .thinking ? _thinkingItalic : _bodyItalic
    }

    static var bodyBoldItalic: PlatformFont {
      activeStyle == .thinking ? _thinkingBoldItalic : _bodyBoldItalic
    }

    static var inlineCode: PlatformFont {
      activeStyle == .thinking ? _thinkingCode : _inlineCode
    }

    static let blockquoteBody = PlatformFont.systemFont(ofSize: TypeScale.reading).withItalic()
  }

  /// Colors for inline elements.
  private enum Colors {
    static var text: PlatformColor {
      activeStyle == .thinking
        ? PlatformColor(Color.textSecondary)
        : PlatformColor(Color.textPrimary)
    }

    static var inlineCode: PlatformColor {
      activeStyle == .thinking
        ? PlatformColor.calibrated(red: 0.95, green: 0.68, blue: 0.45, alpha: 0.7)
        : PlatformColor.calibrated(red: 0.95, green: 0.68, blue: 0.45, alpha: 1)
    }

    static var inlineCodeBg: PlatformColor {
      activeStyle == .thinking
        ? PlatformColor.white.withAlphaComponent(0.06)
        : PlatformColor.white.withAlphaComponent(0.09)
    }

    static let link = PlatformColor.calibrated(red: 0.5, green: 0.72, blue: 0.95, alpha: 1)
    static let blockquoteText = PlatformColor(Color.textSecondary).withAlphaComponent(0.9)
  }

  // MARK: - Helpers

  private static func newlineSpacer(_ points: CGFloat) -> NSAttributedString {
    let para = NSMutableParagraphStyle()
    para.paragraphSpacingBefore = points
    return NSAttributedString(string: "\n", attributes: [
      .font: PlatformFont.systemFont(ofSize: 1),
      .paragraphStyle: para,
    ])
  }

  // MARK: - Block Visitor

  /// Walks the swift-markdown Document AST and produces [MarkdownBlock].
  private struct MarkdownBlockVisitor: MarkupWalker {
    var blocks: [MarkdownBlock] = []

    mutating func visitDocument(_ document: Document) -> [MarkdownBlock] {
      for child in document.children {
        visitBlock(child)
      }
      return blocks
    }

    private mutating func visitBlock(_ markup: any Markup) {
      switch markup {
        case let heading as Heading:
          blocks.append(.text(renderHeading(heading)))

        case let paragraph as Paragraph:
          let attrStr = renderParagraph(paragraph)
          blocks.append(.text(attrStr))

        case let codeBlock as CodeBlock:
          let lang = codeBlock.language.flatMap { lang in
            let trimmed = lang.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : normalizeLanguage(trimmed)
          }
          var code = codeBlock.code
          // Trim trailing newlines
          while code.hasSuffix("\n") {
            code = String(code.dropLast())
          }
          blocks.append(.codeBlock(language: lang, code: code))

        case let blockQuote as BlockQuote:
          let result = NSMutableAttributedString()
          for child in blockQuote.children {
            if let para = child as? Paragraph {
              if result.length > 0 {
                result.append(NSAttributedString(string: "\n"))
              }
              var inlineVisitor = InlineAttributedStringVisitor(
                baseFont: Fonts.blockquoteBody,
                baseColor: Colors.blockquoteText
              )
              let text = NSMutableAttributedString(attributedString: inlineVisitor.renderInlines(para.inlineChildren))
              let quoteStyle = NSMutableParagraphStyle()
              quoteStyle.lineSpacing = textLineSpacing
              quoteStyle.paragraphSpacing = activeStyle == .thinking ? 6 : 10
              if text.length > 0 {
                text.addAttribute(.paragraphStyle, value: quoteStyle, range: NSRange(location: 0, length: text.length))
              }
              result.append(text)
            }
          }
          blocks.append(.blockquote(result))

        case let orderedList as OrderedList:
          blocks.append(.text(renderOrderedList(orderedList)))

        case let unorderedList as UnorderedList:
          blocks.append(.text(renderUnorderedList(unorderedList)))

        case is ThematicBreak:
          blocks.append(.thematicBreak)

        case let table as Markdown.Table:
          blocks.append(renderTable(table))

        case let htmlBlock as HTMLBlock:
          // Render HTML as plain text
          let para = NSMutableParagraphStyle()
          para.paragraphSpacing = paragraphSpacing
          para.lineSpacing = textLineSpacing
          let attrStr = NSAttributedString(string: htmlBlock.rawHTML, attributes: [
            .font: Fonts.body,
            .foregroundColor: Colors.text,
            .paragraphStyle: para,
          ])
          blocks.append(.text(attrStr))

        default:
          // Unknown block — recurse children
          for child in markup.children {
            visitBlock(child)
          }
      }
    }

    // MARK: Heading

    private func renderHeading(_ heading: Heading) -> NSAttributedString {
      let level = min(heading.level, 3)
      let isThinking = activeStyle == .thinking

      let (fontSize, weight, color, topMargin, bottomMargin, kern): (
        CGFloat, PlatformFont.Weight, PlatformColor, CGFloat, CGFloat, CGFloat
      ) = switch level {
        case 1:
          (
            isThinking ? 18 : TypeScale.chatHeading1, .bold,
            isThinking ? PlatformColor(Color.textSecondary) : PlatformColor(Color.textPrimary),
            isThinking ? 16 : 22, isThinking ? 7 : 12, isThinking ? 0 : 0.2
          )
        case 2:
          (
            isThinking ? 15 : TypeScale.chatHeading2, .semibold,
            isThinking
              ? PlatformColor(Color.textSecondary).withAlphaComponent(0.9)
              : PlatformColor(Color.textPrimary).withAlphaComponent(0.95),
            isThinking ? 12 : 18, isThinking ? 5 : 9, isThinking ? 0 : 0.15
          )
        default:
          (
            isThinking ? 13 : TypeScale.chatHeading3, .bold,
            isThinking ? PlatformColor(Color.textSecondary) : PlatformColor(Color.textPrimary).withAlphaComponent(0.88),
            isThinking ? 8 : 14, isThinking ? 3 : 7, isThinking ? 0 : 0.12
          )
      }

      let font = PlatformFont.systemFont(ofSize: fontSize, weight: weight)

      let para = NSMutableParagraphStyle()
      para.paragraphSpacingBefore = topMargin
      para.paragraphSpacing = bottomMargin
      para.lineSpacing = textLineSpacing

      // Render inline children (supports bold/italic/code in headings)
      var inlineVisitor = InlineAttributedStringVisitor(baseFont: font, baseColor: color)
      let result = NSMutableAttributedString(attributedString: inlineVisitor.renderInlines(heading.inlineChildren))
      let fullRange = NSRange(location: 0, length: result.length)
      result.addAttribute(.paragraphStyle, value: para, range: fullRange)
      // Editorial kerning — gives headings a crafted, typeset quality
      if kern > 0 {
        result.addAttribute(.kern, value: kern, range: fullRange)
      }
      return result
    }

    // MARK: Paragraph

    private func renderParagraph(_ paragraph: Paragraph) -> NSAttributedString {
      var inlineVisitor = InlineAttributedStringVisitor(
        baseFont: Fonts.body,
        baseColor: Colors.text
      )
      let result = NSMutableAttributedString(attributedString: inlineVisitor.renderInlines(paragraph.inlineChildren))

      let para = NSMutableParagraphStyle()
      para.paragraphSpacing = paragraphSpacing
      para.lineSpacing = textLineSpacing
      if result.length > 0 {
        result.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: result.length))
      }
      return result
    }

    // MARK: Lists

    private func renderOrderedList(_ list: OrderedList, indentLevel: Int = 0) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for (idx, item) in list.listItems.enumerated() {
        let number = Int(list.startIndex) + idx
        if result.length > 0 { result.append(newlineSpacer(2)) }
        result.append(renderListItem(item, bullet: "\(number). ", indentLevel: indentLevel))
      }
      return result
    }

    private func renderUnorderedList(_ list: UnorderedList, indentLevel: Int = 0) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for item in list.listItems {
        if result.length > 0 { result.append(newlineSpacer(2)) }

        // Check for task list checkbox
        if let checkbox = item.checkbox {
          let marker = checkbox == .checked ? "\u{2611} " : "\u{2610} "
          result.append(renderListItem(item, bullet: marker, indentLevel: indentLevel))
        } else {
          result.append(renderListItem(item, bullet: "\u{2022} ", indentLevel: indentLevel))
        }
      }
      return result
    }

    private enum ListContinuationLine {
      case plain(String)
      case unordered(String)
      case ordered(number: String, text: String)
    }

    private func makeListParagraphStyle(indentLevel: Int) -> NSMutableParagraphStyle {
      let para = NSMutableParagraphStyle()
      let indentStep: CGFloat = 18
      let firstLineIndent = CGFloat(indentLevel) * indentStep
      let bulletWidth: CGFloat = 24 + firstLineIndent
      para.headIndent = bulletWidth
      para.firstLineHeadIndent = firstLineIndent
      para.tabStops = [NSTextTab(textAlignment: .left, location: bulletWidth)]
      para.paragraphSpacingBefore = listParagraphSpacingBefore
      para.paragraphSpacing = listParagraphSpacing
      para.lineSpacing = textLineSpacing
      return para
    }

    private func listBulletAttributes(_ paragraphStyle: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
      [
        .font: Fonts.body,
        .foregroundColor: PlatformColor(Color.textSecondary),
        .paragraphStyle: paragraphStyle,
      ]
    }

    private func parseListContinuation(_ paragraph: Paragraph) -> (firstLine: String, lines: [ListContinuationLine])? {
      let raw = paragraph.format()
      let split = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      guard split.count > 1 else { return nil }

      var parsed: [ListContinuationLine] = []
      var foundMarker = false

      for line in split.dropFirst() {
        let normalized = line.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else {
          parsed.append(.plain(""))
          continue
        }

        if normalized.hasPrefix("- ") || normalized.hasPrefix("* ") || normalized.hasPrefix("+ ") {
          let content = String(normalized.dropFirst(2)).trimmingCharacters(in: .whitespaces)
          parsed.append(.unordered(content))
          foundMarker = true
          continue
        }

        var cursor = normalized.startIndex
        while cursor < normalized.endIndex && normalized[cursor].isNumber {
          cursor = normalized.index(after: cursor)
        }

        if cursor > normalized.startIndex, cursor < normalized.endIndex {
          let marker = normalized[cursor]
          let spaceIndex = normalized.index(after: cursor)
          if (marker == "." || marker == ")"),
             spaceIndex < normalized.endIndex,
             normalized[spaceIndex] == " "
          {
            let number = String(normalized[..<cursor])
            let textStart = normalized.index(after: spaceIndex)
            let text = String(normalized[textStart...]).trimmingCharacters(in: .whitespaces)
            parsed.append(.ordered(number: number, text: text))
            foundMarker = true
            continue
          }
        }

        parsed.append(.plain(normalized))
      }

      guard foundMarker else { return nil }
      return (split[0].trimmingCharacters(in: .whitespacesAndNewlines), parsed)
    }

    private func renderInlineMarkdownLine(
      _ markdown: String,
      paragraphStyle: NSParagraphStyle,
      softBreakAsNewline: Bool
    ) -> NSAttributedString {
      let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return NSAttributedString(string: "") }

      let lineDocument = Document(parsing: trimmed)
      if let paragraph = lineDocument.children.first(where: { $0 is Paragraph }) as? Paragraph {
        var inlineVisitor = InlineAttributedStringVisitor(
          baseFont: Fonts.body,
          baseColor: Colors.text,
          softBreakAsNewline: softBreakAsNewline
        )
        let inline = NSMutableAttributedString(attributedString: inlineVisitor.renderInlines(paragraph.inlineChildren))
        if inline.length > 0 {
          inline.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: inline.length))
        }
        return inline
      }

      return NSAttributedString(string: trimmed, attributes: [
        .font: Fonts.body,
        .foregroundColor: Colors.text,
        .paragraphStyle: paragraphStyle,
      ])
    }

    private func renderListParagraph(
      _ paragraph: Paragraph,
      indentLevel: Int,
      paragraphStyle: NSMutableParagraphStyle
    ) -> NSAttributedString {
      if let continuation = parseListContinuation(paragraph) {
        let result = NSMutableAttributedString()
        if !continuation.firstLine.isEmpty {
          result.append(renderInlineMarkdownLine(
            continuation.firstLine,
            paragraphStyle: paragraphStyle,
            softBreakAsNewline: true
          ))
        }

        for line in continuation.lines {
          if result.length > 0 {
            result.append(NSAttributedString(string: "\n"))
          }

          switch line {
            case let .plain(text):
              if !text.isEmpty {
                result.append(renderInlineMarkdownLine(text, paragraphStyle: paragraphStyle, softBreakAsNewline: true))
              }
            case let .unordered(text):
              let nestedStyle = makeListParagraphStyle(indentLevel: indentLevel + 1)
              result.append(NSAttributedString(
                string: "\t\u{2022} ",
                attributes: listBulletAttributes(nestedStyle)
              ))
              result.append(renderInlineMarkdownLine(text, paragraphStyle: nestedStyle, softBreakAsNewline: true))
            case let .ordered(number, text):
              let nestedStyle = makeListParagraphStyle(indentLevel: indentLevel + 1)
              result.append(NSAttributedString(
                string: "\t\(number). ",
                attributes: listBulletAttributes(nestedStyle)
              ))
              result.append(renderInlineMarkdownLine(text, paragraphStyle: nestedStyle, softBreakAsNewline: true))
          }
        }

        return result
      }

      var inlineVisitor = InlineAttributedStringVisitor(
        baseFont: Fonts.body,
        baseColor: Colors.text,
        softBreakAsNewline: true
      )
      let inline = NSMutableAttributedString(attributedString: inlineVisitor.renderInlines(paragraph.inlineChildren))
      if inline.length > 0 {
        inline.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: inline.length))
      }
      return inline
    }

    private func renderListItem(_ item: ListItem, bullet: String, indentLevel: Int) -> NSAttributedString {
      let result = NSMutableAttributedString()

      let para = makeListParagraphStyle(indentLevel: indentLevel)
      let bulletAttrs = listBulletAttributes(para)
      result.append(NSAttributedString(string: "\t" + bullet, attributes: bulletAttrs))

      // Render list content. Support paragraphs, fenced code, and fallback plain text.
      var didRenderPrimaryContent = false
      for child in item.children {
        if let paragraph = child as? Paragraph {
          if didRenderPrimaryContent {
            result.append(NSAttributedString(string: "\n"))
          }
          result.append(renderListParagraph(paragraph, indentLevel: indentLevel, paragraphStyle: para))
          didRenderPrimaryContent = true
        } else if let codeBlock = child as? CodeBlock {
          if didRenderPrimaryContent {
            result.append(NSAttributedString(string: "\n"))
          }
          var code = codeBlock.code
          while code.hasSuffix("\n") {
            code = String(code.dropLast())
          }
          guard !code.isEmpty else { continue }
          let codePara = para.mutableCopy() as! NSMutableParagraphStyle
          codePara.paragraphSpacingBefore = max(2, para.paragraphSpacingBefore)
          let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: Fonts.inlineCode,
            .foregroundColor: Colors.text,
            .backgroundColor: Colors.inlineCodeBg,
            .paragraphStyle: codePara,
          ]
          result.append(NSAttributedString(string: "\n\(code)", attributes: codeAttrs))
          didRenderPrimaryContent = true
        } else if let nestedOrdered = child as? OrderedList {
          if didRenderPrimaryContent {
            result.append(NSAttributedString(string: "\n"))
          }
          result.append(renderOrderedList(nestedOrdered, indentLevel: indentLevel + 1))
          didRenderPrimaryContent = true
        } else if let nestedUnordered = child as? UnorderedList {
          if didRenderPrimaryContent {
            result.append(NSAttributedString(string: "\n"))
          }
          result.append(renderUnorderedList(nestedUnordered, indentLevel: indentLevel + 1))
          didRenderPrimaryContent = true
        } else {
          let plain = child.format().trimmingCharacters(in: .whitespacesAndNewlines)
          guard !plain.isEmpty else { continue }
          if didRenderPrimaryContent {
            result.append(NSAttributedString(string: "\n"))
          }
          let attrs: [NSAttributedString.Key: Any] = [
            .font: Fonts.body,
            .foregroundColor: Colors.text,
            .paragraphStyle: para,
          ]
          result.append(NSAttributedString(string: plain, attributes: attrs))
          didRenderPrimaryContent = true
        }
      }

      return result
    }

    // MARK: Table

    private func renderTable(_ table: Markdown.Table) -> MarkdownBlock {
      let headers: [String] = table.head.cells.map { cell in
        cell.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      var rows: [[String]] = []
      for row in table.body.rows {
        let cells: [String] = row.cells.map { cell in
          cell.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Pad or trim to match header count
        let padded = cells + Array(repeating: "", count: max(0, headers.count - cells.count))
        rows.append(Array(padded.prefix(headers.count)))
      }

      return .table(headers: headers, rows: rows)
    }
  }

  // MARK: - Inline Visitor

  /// Walks inline markup nodes and produces NSMutableAttributedString.
  /// Tracks bold/italic state for correct nesting (***bold italic***).
  private struct InlineAttributedStringVisitor {
    let baseFont: PlatformFont
    let baseColor: PlatformColor
    let softBreakAsNewline: Bool
    private var isBold = false
    private var isItalic = false
    private var activeLinkURL: URL?
    private var isInsideMarkdownLink = false

    init(baseFont: PlatformFont, baseColor: PlatformColor, softBreakAsNewline: Bool = false) {
      self.baseFont = baseFont
      self.baseColor = baseColor
      self.softBreakAsNewline = softBreakAsNewline
    }

    private func resolveFont() -> PlatformFont {
      if isBold, isItalic { return Fonts.bodyBoldItalic }
      if isBold { return Fonts.bodyBold }
      if isItalic { return Fonts.bodyItalic }
      return baseFont
    }

    mutating func renderInlines(_ inlines: some Sequence<InlineMarkup>) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for inline in inlines {
        renderInline(inline, into: result)
      }
      return result
    }

    private func applyLinkStyleIfNeeded(
      to attributes: [NSAttributedString.Key: Any],
      explicitLink: URL?
    ) -> [NSAttributedString.Key: Any] {
      let shouldStyleAsLink = isInsideMarkdownLink || explicitLink != nil
      guard shouldStyleAsLink else { return attributes }

      var merged = attributes
      merged[.foregroundColor] = Colors.link
      merged[.underlineStyle] = NSUnderlineStyle.single.rawValue
      if let explicitLink {
        merged[.link] = explicitLink
      }
      return merged
    }

    private mutating func appendText(
      _ text: String,
      attributes baseAttributes: [NSAttributedString.Key: Any],
      into result: NSMutableAttributedString,
      detectInlineLinks: Bool = true
    ) {
      guard !text.isEmpty else { return }

      // Inside explicit markdown link: preserve nested styles, apply link treatment.
      if isInsideMarkdownLink {
        let styled = applyLinkStyleIfNeeded(to: baseAttributes, explicitLink: activeLinkURL)
        result.append(NSAttributedString(string: text, attributes: styled))
        return
      }

      // Outside markdown links: auto-link bare URLs in plain text.
      guard detectInlineLinks, let detector = MarkdownAttributedStringRenderer.linkDetector else {
        result.append(NSAttributedString(string: text, attributes: baseAttributes))
        return
      }

      let nsText = text as NSString
      let fullRange = NSRange(location: 0, length: nsText.length)
      let matches = detector.matches(in: text, options: [], range: fullRange)
      guard !matches.isEmpty else {
        result.append(NSAttributedString(string: text, attributes: baseAttributes))
        return
      }

      var cursor = 0
      for match in matches where match.resultType == .link {
        let range = match.range
        guard range.location >= cursor else { continue }

        if range.location > cursor {
          let prefix = nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
          result.append(NSAttributedString(string: prefix, attributes: baseAttributes))
        }

        let token = nsText.substring(with: range)
        let linkedURL = match.url.flatMap { MarkdownAttributedStringRenderer.isAllowedURL($0) ? $0 : nil }
          ?? MarkdownAttributedStringRenderer.normalizedURL(token)
        let attrs = applyLinkStyleIfNeeded(to: baseAttributes, explicitLink: linkedURL)
        result.append(NSAttributedString(string: token, attributes: attrs))
        cursor = range.location + range.length
      }

      if cursor < nsText.length {
        let suffix = nsText.substring(from: cursor)
        result.append(NSAttributedString(string: suffix, attributes: baseAttributes))
      }
    }

    private mutating func renderInline(_ markup: any InlineMarkup, into result: NSMutableAttributedString) {
      switch markup {
        case let text as Markdown.Text:
          appendText(text.string, attributes: [
            .font: resolveFont(),
            .foregroundColor: baseColor,
          ], into: result)

        case let strong as Strong:
          let wasBold = isBold
          isBold = true
          for child in strong.inlineChildren {
            renderInline(child, into: result)
          }
          isBold = wasBold

        case let emphasis as Emphasis:
          let wasItalic = isItalic
          isItalic = true
          for child in emphasis.inlineChildren {
            renderInline(child, into: result)
          }
          isItalic = wasItalic

        case let code as InlineCode:
          appendText(code.code, attributes: [
            .font: Fonts.inlineCode,
            .foregroundColor: Colors.inlineCode,
            .backgroundColor: Colors.inlineCodeBg,
          ], into: result, detectInlineLinks: false)

        case let link as Markdown.Link:
          let previousURL = activeLinkURL
          let previousInsideLink = isInsideMarkdownLink
          activeLinkURL = link.destination.flatMap { MarkdownAttributedStringRenderer.normalizedURL($0) }
          isInsideMarkdownLink = true
          for child in link.inlineChildren {
            renderInline(child, into: result)
          }
          activeLinkURL = previousURL
          isInsideMarkdownLink = previousInsideLink

        case let image as Markdown.Image:
          let altText = image.plainText.isEmpty ? (image.source ?? "image") : image.plainText
          guard !altText.isEmpty else { return }
          let previousURL = activeLinkURL
          let previousInsideLink = isInsideMarkdownLink
          activeLinkURL = image.source.flatMap { MarkdownAttributedStringRenderer.normalizedURL($0) }
          isInsideMarkdownLink = true
          appendText(altText, attributes: [
            .font: resolveFont(),
            .foregroundColor: baseColor,
          ], into: result, detectInlineLinks: false)
          activeLinkURL = previousURL
          isInsideMarkdownLink = previousInsideLink

        case let strikethrough as Markdown.Strikethrough:
          for child in strikethrough.inlineChildren {
            let before = result.length
            renderInline(child, into: result)
            let after = result.length
            if after > before {
              result.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: before, length: after - before)
              )
            }
          }

        case is SoftBreak:
          appendText(softBreakAsNewline ? "\n" : " ", attributes: [
            .font: resolveFont(),
            .foregroundColor: baseColor,
          ], into: result, detectInlineLinks: false)

        case is LineBreak:
          appendText("\n", attributes: [
            .font: resolveFont(),
            .foregroundColor: baseColor,
          ], into: result, detectInlineLinks: false)

        case let html as InlineHTML:
          // Render raw HTML as plain text
          appendText(html.rawHTML, attributes: [
            .font: resolveFont(),
            .foregroundColor: baseColor,
          ], into: result, detectInlineLinks: false)

        default:
          // Unknown inline — try children, else render plain text
          let children = Array(markup.children)
          if !children.isEmpty {
            for child in children {
              if let inlineChild = child as? any InlineMarkup {
                renderInline(inlineChild, into: result)
              }
            }
          } else {
            appendText(markup.plainText, attributes: [
              .font: resolveFont(),
              .foregroundColor: baseColor,
            ], into: result)
          }
      }
    }
  }
}
