//
//  MarkdownSystemParser.swift
//  OrbitDock
//
//  Markdown parser: swift-markdown AST walker for block structure,
//  outputs [MarkdownBlock] with raw markdown strings for SwiftUI Text rendering.
//

import Foundation
import Markdown

enum MarkdownSystemParser {
  // MARK: - Cache

  private struct CacheKey: Hashable {
    let markdown: String
    let style: ContentStyle
  }

  private struct CacheEntry {
    let blocks: [MarkdownBlock]
    var accessTick: UInt64
  }

  private static var parseCache: [CacheKey: CacheEntry] = [:]
  private static var parseCacheTick: UInt64 = 0
  #if os(iOS)
    private static let maxCacheSize = 160
  #else
    private static let maxCacheSize = 500
  #endif
  private static let evictionBatchSize = 64

  /// Two-space gap between list marker and content (inlined from deleted MarkdownTypography).
  private static let listMarkerGap = "  "

  // MARK: - Public API

  static func parse(_ markdown: String, style: ContentStyle = .standard) -> [MarkdownBlock] {
    let key = CacheKey(markdown: markdown, style: style)
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

  // MARK: - Parsing

  private static func parseUncached(_ markdown: String, style: ContentStyle) -> [MarkdownBlock] {
    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

    let document = Document(parsing: markdown)
    var blocks: [MarkdownBlock] = []

    for child in document.children {
      appendBlock(from: child, style: style, into: &blocks)
    }

    return blocks
  }

  // MARK: - Block Builder

  private static func appendBlock(from markup: any Markup, style: ContentStyle, into blocks: inout [MarkdownBlock]) {
    switch markup {
      case let codeBlock as CodeBlock:
        var code = codeBlock.code
        while code.hasSuffix("\n") { code = String(code.dropLast()) }
        blocks.append(.codeBlock(language: MarkdownLanguage.normalize(codeBlock.language), code: code))

      case let table as Markdown.Table:
        blocks.append(tableBlock(from: table))

      case is ThematicBreak:
        blocks.append(.thematicBreak)

      case let blockQuote as BlockQuote:
        let text = blockquoteText(from: blockQuote)
        if !text.isEmpty { blocks.append(.blockquote(text)) }

      case let paragraph as Paragraph:
        let text = markdownSource(for: paragraph).trimmingCharacters(in: .newlines)
        if !text.isEmpty { blocks.append(.text(text)) }

      case let heading as Heading:
        let text = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          blocks.append(.heading(level: heading.level, text: text))
        }

      case let list as OrderedList:
        let text = normalizeListDisplaySource(markdownSource(for: list)).trimmingCharacters(in: .newlines)
        if !text.isEmpty { blocks.append(.text(text)) }

      case let list as UnorderedList:
        let text = normalizeListDisplaySource(markdownSource(for: list)).trimmingCharacters(in: .newlines)
        if !text.isEmpty { blocks.append(.text(text)) }

      case let htmlBlock as HTMLBlock:
        let text = htmlBlock.rawHTML.trimmingCharacters(in: .newlines)
        if !text.isEmpty { blocks.append(.text(text)) }

      default:
        for child in markup.children { appendBlock(from: child, style: style, into: &blocks) }
    }
  }

  // MARK: - Blockquote

  private static func blockquoteText(from blockQuote: BlockQuote) -> String {
    var parts: [String] = []
    for child in blockQuote.children {
      switch child {
        case let p as Paragraph:
          let t = markdownSource(for: p).trimmingCharacters(in: .newlines)
          if !t.isEmpty { parts.append(t) }
        case let h as Heading:
          let t = h.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
          if !t.isEmpty { parts.append(h.level <= 3 ? "**\(t)**" : t) }
        case let ol as OrderedList:
          let t = normalizeListDisplaySource(markdownSource(for: ol)).trimmingCharacters(in: .newlines)
          if !t.isEmpty { parts.append(t) }
        case let ul as UnorderedList:
          let t = normalizeListDisplaySource(markdownSource(for: ul)).trimmingCharacters(in: .newlines)
          if !t.isEmpty { parts.append(t) }
        case let nested as BlockQuote:
          let t = blockquoteText(from: nested)
          if !t.isEmpty { parts.append(t) }
        case let code as CodeBlock:
          var c = code.code; while c.hasSuffix("\n") { c = String(c.dropLast()) }
          if !c.isEmpty { parts.append(c) }
        default:
          let t = markdownSource(for: child).trimmingCharacters(in: .newlines)
          if !t.isEmpty { parts.append(t) }
      }
    }
    return parts.joined(separator: "\n\n")
  }

  // MARK: - Table

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
    let source = cell.children
      .map { markdownSource(for: $0) }
      .joined(separator: "\n")
    return source.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Source Extraction

  private static func markdownSource(for markup: any Markup) -> String {
    let detached = markup.detachedFromParent
    return detached.format()
  }

  // MARK: - List Normalization

  private static func normalizeListDisplaySource(_ source: String) -> String {
    var normalized = source
    normalized = renumberOrderedListMarkers(in: normalized)
    normalized = normalized.replacingOccurrences(
      of: #"(?m)^(\s*)[-+*]\s+\[(?:x|X)\]\s+"#,
      with: "$1☑\(listMarkerGap)",
      options: .regularExpression
    )
    normalized = normalized.replacingOccurrences(
      of: #"(?m)^(\s*)[-+*]\s+\[\s\]\s+"#,
      with: "$1☐\(listMarkerGap)",
      options: .regularExpression
    )
    normalized = normalized.replacingOccurrences(
      of: #"(?m)^(\s*)[-+*]\s+"#,
      with: "$1•\(listMarkerGap)",
      options: .regularExpression
    )
    normalized = normalized.replacingOccurrences(
      of: #"(?m)^(\s*)(\d+)[.)]\s+"#,
      with: "$1$2.\(listMarkerGap)",
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

  // MARK: - Cache Machinery

  private static func nextParseCacheTick() -> UInt64 {
    parseCacheTick &+= 1
    return parseCacheTick
  }

  private static func insertCacheValue(_ value: [MarkdownBlock], for key: CacheKey) {
    if parseCache[key] == nil {
      evictIfNeeded()
    }

    parseCache[key] = CacheEntry(blocks: value, accessTick: nextParseCacheTick())
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
}
