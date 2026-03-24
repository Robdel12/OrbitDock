//
//  MarkdownProseAttributedStringBuilder.swift
//  OrbitDock
//
//  Builds one attributed prose surface from contiguous prose-capable markdown
//  blocks. The output is intended for a single SwiftUI Text-backed renderer.
//

import Foundation
import SwiftUI

struct MarkdownProseAttributedStringBuilder {
  let style: ContentStyle

  init(style: ContentStyle = .standard) {
    self.style = style
  }

  static func build(
    from blocks: [MarkdownBlock],
    style: ContentStyle = .standard
  ) -> AttributedString {
    MarkdownProseAttributedStringBuilder(style: style).build(from: blocks)
  }

  static func inlineMarkdown(
    _ markdown: String,
    style: ContentStyle = .standard,
    foregroundColor: Color? = nil
  ) -> AttributedString {
    MarkdownProseAttributedStringBuilder(style: style).styledInlineAttributedString(
      markdown,
      font: MarkdownTypography.bodyFont(style: style),
      foregroundColor: foregroundColor
    ) ?? AttributedString(markdown)
  }

  func build(from blocks: [MarkdownBlock]) -> AttributedString {
    var result = AttributedString()
    var previousBlock: MarkdownBlock?

    for block in blocks {
      guard let fragment = buildFragment(for: block) else { continue }
      if let previousBlock {
        result.append(blockSeparator(previous: previousBlock, current: block))
      }
      result.append(fragment)
      previousBlock = block
    }

    return result
  }

  private func buildFragment(for block: MarkdownBlock) -> AttributedString? {
    switch block {
      case let .text(text):
        return styledInlineAttributedString(
          text,
          font: MarkdownTypography.bodyFont(style: style),
          foregroundColor: bodyForegroundColor
        )

      case let .heading(level, text):
        return styledInlineAttributedString(
          text,
          font: MarkdownTypography.headingFont(level: level, style: style),
          foregroundColor: MarkdownTypography.headingColor(level: level)
        )

      case let .blockquote(text):
        return buildBlockquote(text)

      case let .list(items):
        return buildList(items, depth: 0)

      case .codeBlock, .table, .thematicBreak:
        return nil
    }
  }

  private func buildBlockquote(_ text: String) -> AttributedString {
    var result = AttributedString()
    let paragraphs = text.components(separatedBy: "\n\n")
    let bodyFont = MarkdownTypography.bodyFont(style: style)
    let quoteColor = MarkdownTypography.blockquoteForegroundColor(style: style)
    let quotePrefixColor = MarkdownTypography.blockquotePrefixColor(style: style)
    let quotePrefix = MarkdownTypography.blockquotePrefix(style: style)

    for (index, paragraph) in paragraphs.enumerated() {
      if index > 0 {
        result.append(AttributedString("\n\n"))
      }

      result.append(styledPrefix(quotePrefix, font: bodyFont, foregroundColor: quotePrefixColor))
      if let paragraphString = styledInlineAttributedString(
           paragraph,
           font: bodyFont,
           foregroundColor: quoteColor
         ) {
        result.append(paragraphString)
      }
    }

    return result
  }

  private func buildList(_ items: [ListItem], depth: Int) -> AttributedString {
    var result = AttributedString()

    for (index, item) in items.enumerated() {
      if index > 0 {
        result.append(AttributedString("\n"))
      }
      result.append(buildListItem(item, depth: depth))
    }

    return result
  }

  private func buildListItem(_ item: ListItem, depth: Int) -> AttributedString {
    let bodyFont = MarkdownTypography.bodyFont(style: style)
    let indent = MarkdownTypography.listIndentString(depth: depth)
    let marker = item.marker.display
    let markerPrefix = indent + marker + " "
    let continuationIndent = indent + String(repeating: " ", count: marker.count + 1)

    var result = AttributedString()
    result.append(
      styledPrefix(
        markerPrefix,
        font: bodyFont,
        foregroundColor: MarkdownTypography.listMarkerColor(item.marker)
      )
    )

    if let content = styledInlineAttributedString(
      item.content,
      font: bodyFont,
      foregroundColor: bodyForegroundColor
    ) {
      result.append(content)
    }

    for continuation in item.continuation {
      result.append(AttributedString(MarkdownTypography.listContinuationSpacing(style: style)))
      result.append(
        styledPrefix(
          continuationIndent,
          font: bodyFont,
          foregroundColor: bodyForegroundColor
        )
      )
      if let paragraph = styledInlineAttributedString(
        continuation,
        font: bodyFont,
        foregroundColor: bodyForegroundColor
      ) {
        result.append(paragraph)
      }
    }

    if !item.children.isEmpty {
      result.append(AttributedString(MarkdownTypography.listChildSpacing(style: style)))
      result.append(buildList(item.children, depth: depth + 1))
    }

    return result
  }

  private func styledInlineAttributedString(
    _ markdown: String,
    font: Font,
    foregroundColor: Color?
  ) -> AttributedString? {
    guard let parsed = try? AttributedString(
      markdown: markdown,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) else {
      return nil
    }

    var result = parsed
    result.font = font
    if let foregroundColor {
      result.foregroundColor = foregroundColor
    }
    return MarkdownTypography.applyInlineCodeStyle(result, style: style)
  }

  private var bodyForegroundColor: Color {
    MarkdownTypography.bodyForegroundColor(style: style)
  }

  private func styledPrefix(
    _ text: String,
    font: Font,
    foregroundColor: Color
  ) -> AttributedString {
    var result = AttributedString(text)
    result.font = font
    result.foregroundColor = foregroundColor
    return result
  }

  private func blockSeparator(previous: MarkdownBlock, current: MarkdownBlock) -> AttributedString {
    switch (previous, current) {
      case (.heading, _):
        return AttributedString("\n")
      case (.blockquote, .blockquote):
        return AttributedString("\n")
      default:
        return AttributedString(MarkdownTypography.paragraphSpacing(style: style))
    }
  }
}
