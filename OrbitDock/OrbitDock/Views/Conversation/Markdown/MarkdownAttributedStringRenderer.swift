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
  /// Parse cache — avoids re-parsing identical content.
  private static var parseCache: [Int: [MarkdownBlock]] = [:]
  #if os(iOS)
    private static let maxCacheSize = 160
  #else
    private static let maxCacheSize = 500
  #endif

  /// Active style context — set during parse, read by Fonts/Colors.
  /// Safe because all rendering is @MainActor.
  private static var activeStyle: ContentStyle = .standard

  /// Parse markdown text into blocks, with caching by content hash.
  static func parse(_ markdown: String, style: ContentStyle = .standard) -> [MarkdownBlock] {
    let hash = markdown.hashValue &+ (style == .thinking ? 1 : 0)
    if let cached = parseCache[hash] { return cached }

    activeStyle = style
    let document = Document(parsing: markdown)
    var visitor = MarkdownBlockVisitor()
    let blocks = visitor.visitDocument(document)
    activeStyle = .standard

    if parseCache.count >= maxCacheSize {
      parseCache.removeAll(keepingCapacity: true)
    }
    parseCache[hash] = blocks
    return blocks
  }

  /// Clear parse cache (call on memory pressure).
  static func clearCache() {
    parseCache.removeAll(keepingCapacity: true)
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

  /// Line spacing — proportional to body font size.
  /// Standard (14.5pt): 6.5pt → ~21pt total (1.45× ratio, approaching WCAG 1.5×).
  /// Thinking (13pt): 4.5pt → ~17.5pt total (1.35× ratio, compact but readable).
  static var textLineSpacing: CGFloat {
    activeStyle == .thinking ? 4.5 : 6.5
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
              let text = inlineVisitor.renderInlines(para.inlineChildren)
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
          para.paragraphSpacing = activeStyle == .thinking ? 8 : 12
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

      #if os(macOS)
        typealias FontDesign = NSFontDescriptor.SystemDesign
      #else
        typealias FontDesign = UIFontDescriptor.SystemDesign
      #endif

      let (fontSize, weight, design, color, topMargin, bottomMargin, kern): (
        CGFloat, PlatformFont.Weight, FontDesign?, PlatformColor, CGFloat, CGFloat, CGFloat
      ) = switch level {
        case 1:
          (
            isThinking ? 18 : TypeScale.chatHeading1, .bold, .serif,
            isThinking ? PlatformColor(Color.textSecondary) : PlatformColor(Color.textPrimary),
            isThinking ? 18 : 26, isThinking ? 8 : 14, isThinking ? 0 : 0.3
          )
        case 2:
          (
            isThinking ? 15 : TypeScale.chatHeading2, .semibold, .serif,
            isThinking
              ? PlatformColor(Color.textSecondary).withAlphaComponent(0.9)
              : PlatformColor(Color.textPrimary).withAlphaComponent(0.95),
            isThinking ? 14 : 22, isThinking ? 6 : 10, isThinking ? 0 : 0.2
          )
        default:
          (
            isThinking ? 13 : TypeScale.chatHeading3, .bold, nil,
            isThinking ? PlatformColor(Color.textSecondary) : PlatformColor(Color.textPrimary).withAlphaComponent(0.88),
            isThinking ? 10 : 16, isThinking ? 4 : 8, isThinking ? 0 : 0.5
          )
      }

      var font = PlatformFont.systemFont(ofSize: fontSize, weight: weight)
      if let design, let styled = font.withDesign(design) {
        font = styled
      }

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
      para.paragraphSpacing = activeStyle == .thinking ? 8 : 14
      para.lineSpacing = textLineSpacing
      if result.length > 0 {
        result.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: result.length))
      }
      return result
    }

    // MARK: Lists

    private func renderOrderedList(_ list: OrderedList) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for (idx, item) in list.listItems.enumerated() {
        let number = Int(list.startIndex) + idx
        if result.length > 0 { result.append(newlineSpacer(2)) }
        result.append(renderListItem(item, bullet: "\(number). "))
      }
      return result
    }

    private func renderUnorderedList(_ list: UnorderedList) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for item in list.listItems {
        if result.length > 0 { result.append(newlineSpacer(2)) }

        // Check for task list checkbox
        if let checkbox = item.checkbox {
          let marker = checkbox == .checked ? "\u{2611} " : "\u{2610} "
          result.append(renderListItem(item, bullet: marker))
        } else {
          result.append(renderListItem(item, bullet: "\u{2022} "))
        }
      }
      return result
    }

    private func renderListItem(_ item: ListItem, bullet: String) -> NSAttributedString {
      let result = NSMutableAttributedString()

      let para = NSMutableParagraphStyle()
      let bulletWidth: CGFloat = 20
      para.headIndent = bulletWidth
      para.firstLineHeadIndent = 0
      para.tabStops = [NSTextTab(textAlignment: .left, location: bulletWidth)]
      para.paragraphSpacingBefore = activeStyle == .thinking ? 1 : 3
      para.paragraphSpacing = activeStyle == .thinking ? 2 : 5
      para.lineSpacing = textLineSpacing

      let bulletAttrs: [NSAttributedString.Key: Any] = [
        .font: Fonts.body,
        .foregroundColor: PlatformColor(Color.textSecondary),
        .paragraphStyle: para,
      ]
      result.append(NSAttributedString(string: "\t" + bullet, attributes: bulletAttrs))

      // Render inline content from paragraph children
      for child in item.children {
        if let paragraph = child as? Paragraph {
          var inlineVisitor = InlineAttributedStringVisitor(
            baseFont: Fonts.body,
            baseColor: Colors.text
          )
          let inlineStr = NSMutableAttributedString(attributedString: inlineVisitor
            .renderInlines(paragraph.inlineChildren))
          inlineStr.addAttribute(
            .paragraphStyle,
            value: para,
            range: NSRange(location: 0, length: inlineStr.length)
          )
          result.append(inlineStr)
        }
      }

      return result
    }

    // MARK: Table

    private func renderTable(_ table: Markdown.Table) -> MarkdownBlock {
      let headers: [String] = table.head.cells.map { cell in
        cell.plainText.trimmingCharacters(in: .whitespaces)
      }

      var rows: [[String]] = []
      for row in table.body.rows {
        let cells: [String] = row.cells.map { cell in
          cell.plainText.trimmingCharacters(in: .whitespaces)
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
    private var isBold = false
    private var isItalic = false

    init(baseFont: PlatformFont, baseColor: PlatformColor) {
      self.baseFont = baseFont
      self.baseColor = baseColor
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

    private mutating func renderInline(_ markup: any InlineMarkup, into result: NSMutableAttributedString) {
      switch markup {
        case let text as Markdown.Text:
          result.append(NSAttributedString(string: text.string, attributes: [
            .font: resolveFont(),
            .foregroundColor: baseColor,
          ]))

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
          result.append(NSAttributedString(string: code.code, attributes: [
            .font: Fonts.inlineCode,
            .foregroundColor: Colors.inlineCode,
            .backgroundColor: Colors.inlineCodeBg,
          ]))

        case let link as Markdown.Link:
          var attrs: [NSAttributedString.Key: Any] = [
            .font: resolveFont(),
            .foregroundColor: Colors.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
          ]
          if let dest = link.destination, let nsURL = URL(string: dest) {
            attrs[.link] = nsURL
          }
          // Render link's inline children (may contain bold/italic/code)
          for child in link.inlineChildren {
            switch child {
              case let text as Markdown.Text:
                result.append(NSAttributedString(string: text.string, attributes: attrs))
              default:
                renderInline(child, into: result)
            }
          }

        case let image as Markdown.Image:
          // Render as link-style text with alt text
          let altText = image.plainText
          if !altText.isEmpty {
            var attrs: [NSAttributedString.Key: Any] = [
              .font: resolveFont(),
              .foregroundColor: Colors.link,
              .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            if let src = image.source, let nsURL = URL(string: src) {
              attrs[.link] = nsURL
            }
            result.append(NSAttributedString(string: altText, attributes: attrs))
          }

        case is Markdown.Strikethrough:
          let strikethrough = markup as! Markdown.Strikethrough
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
          result.append(NSAttributedString(string: " ", attributes: [
            .font: resolveFont(),
            .foregroundColor: baseColor,
          ]))

        case is LineBreak:
          result.append(NSAttributedString(string: "\n", attributes: [
            .font: resolveFont(),
            .foregroundColor: baseColor,
          ]))

        case let html as InlineHTML:
          // Render raw HTML as plain text
          result.append(NSAttributedString(string: html.rawHTML, attributes: [
            .font: resolveFont(),
            .foregroundColor: baseColor,
          ]))

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
            result.append(NSAttributedString(string: markup.plainText, attributes: [
              .font: resolveFont(),
              .foregroundColor: baseColor,
            ]))
          }
      }
    }
  }
}
