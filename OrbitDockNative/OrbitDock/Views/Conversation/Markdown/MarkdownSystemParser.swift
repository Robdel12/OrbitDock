//
//  MarkdownSystemParser.swift
//  OrbitDock
//
//  Markdown parser: swift-markdown AST walker for block structure,
//  outputs [MarkdownBlock] with raw markdown strings for SwiftUI Text rendering.
//

import Foundation
import Markdown
import os

enum MarkdownSystemParser {
  // MARK: - Cache

  private nonisolated struct CacheKey: Hashable, Sendable {
    let markdown: String
    let style: ContentStyle
  }

  private nonisolated struct CacheEntry: Sendable {
    let blocks: [MarkdownBlock]
    var accessTick: UInt64
  }

  private nonisolated struct CacheState: Sendable {
    var entries: [CacheKey: CacheEntry] = [:]
    var tick: UInt64 = 0
  }

  private static let cache = OSAllocatedUnfairLock(initialState: CacheState())

  #if os(iOS)
    nonisolated private static let maxCacheSize = 160
  #else
    nonisolated private static let maxCacheSize = 500
  #endif
  nonisolated private static let evictionBatchSize = 64

  /// Two-space gap between list marker and content (inlined from deleted MarkdownTypography).
  private static let listMarkerGap = "  "

  // MARK: - Public API

  static func parse(_ markdown: String, style: ContentStyle = .standard) -> [MarkdownBlock] {
    let key = CacheKey(markdown: markdown, style: style)

    if let cached = cache.withLock({ state -> [MarkdownBlock]? in
      if var entry = state.entries[key] {
        state.tick &+= 1
        entry.accessTick = state.tick
        state.entries[key] = entry
        return entry.blocks
      }
      return nil
    }) {
      return cached
    }

    let blocks = parseUncached(markdown, style: style)

    cache.withLock { state in
      if state.entries[key] == nil {
        evictIfNeeded(state: &state)
      }
      state.tick &+= 1
      state.entries[key] = CacheEntry(blocks: blocks, accessTick: state.tick)
    }

    return blocks
  }

  static func clearCache() {
    cache.withLock { state in
      state.entries.removeAll(keepingCapacity: true)
      state.tick = 0
    }
  }

  // MARK: - Parsing

  private static func parseUncached(_ markdown: String, style: ContentStyle) -> [MarkdownBlock] {
    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

    let normalizedMarkdown = normalizeChatListContinuations(in: markdown)
    let document = Document(parsing: normalizedMarkdown)
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
        while code.hasSuffix("\n") {
          code = String(code.dropLast())
        }
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
        let items = parseOrderedList(list)
        if !items.isEmpty { blocks.append(.list(items)) }

      case let list as UnorderedList:
        let items = parseUnorderedList(list)
        if !items.isEmpty { blocks.append(.list(items)) }

      case let htmlBlock as HTMLBlock:
        let text = htmlBlock.rawHTML.trimmingCharacters(in: .newlines)
        if !text.isEmpty { blocks.append(.text(text)) }

      default:
        for child in markup.children {
          appendBlock(from: child, style: style, into: &blocks)
        }
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
          var c = code.code; while c.hasSuffix("\n") {
            c = String(c.dropLast())
          }
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

  // MARK: - List Parsing

  private static func parseOrderedList(_ list: OrderedList) -> [ListItem] {
    var items: [ListItem] = []
    var number = 1
    for child in list.children {
      guard let node = child as? Markdown.ListItem else { continue }
      items.append(parseListItemNode(node, marker: .number(number)))
      number += 1
    }
    return items
  }

  private static func parseUnorderedList(_ list: UnorderedList) -> [ListItem] {
    list.children.compactMap { child -> ListItem? in
      guard let node = child as? Markdown.ListItem else { return nil }
      let marker: ListMarker = if let checkbox = node.checkbox {
        checkbox == .checked ? .checked : .unchecked
      } else {
        .bullet
      }
      return parseListItemNode(node, marker: marker)
    }
  }

  private static func parseListItemNode(_ node: Markdown.ListItem, marker: ListMarker) -> ListItem {
    var content = ""
    var continuation: [String] = []
    var children: [ListItem] = []
    var isFirst = true

    for child in node.children {
      switch child {
        case let p as Paragraph:
          let segments = splitListParagraphSegments(markdownSource(for: p))
          for segment in segments {
            if isFirst {
              content = segment
              isFirst = false
            } else if !segment.isEmpty {
              continuation.append(segment)
            }
          }
        case let ol as OrderedList:
          children.append(contentsOf: parseOrderedList(ol))
        case let ul as UnorderedList:
          children.append(contentsOf: parseUnorderedList(ul))
        default:
          let segments = splitListParagraphSegments(markdownSource(for: child))
          for segment in segments where !segment.isEmpty {
            if isFirst {
              content = segment
              isFirst = false
            } else {
              continuation.append(segment)
            }
          }
      }
    }

    return ListItem(marker: marker, content: content, continuation: continuation, children: children)
  }

  // MARK: - List Normalization (blockquote use only)

  private struct ListLineContext {
    let indentCount: Int
    let continuationIndent: String
  }

  private static func normalizeChatListContinuations(in source: String) -> String {
    var lines = source.components(separatedBy: "\n")
    var activeListContext: ListLineContext?
    var insideCodeFence = false
    var index = 0

    while index < lines.count {
      let line = lines[index]

      if togglesCodeFence(line) {
        insideCodeFence.toggle()
        activeListContext = nil
        index += 1
        continue
      }

      if insideCodeFence {
        index += 1
        continue
      }

      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        index += 1
        continue
      }

      if let listContext = parseListLineContext(from: line) {
        activeListContext = listContext
        index += 1
        continue
      }

      guard let activeListContext,
            shouldNormalizeLooseContinuation(
              startingAt: index,
              lines: lines,
              activeListContext: activeListContext
            )
      else {
        activeListContext = nil
        index += 1
        continue
      }

      lines.insert(activeListContext.continuationIndent, at: index)
      index += 1

      while index < lines.count {
        let candidate = lines[index]
        if candidate.trimmingCharacters(in: .whitespaces).isEmpty { break }
        if parseListLineContext(from: candidate) != nil { break }
        if hasLeadingWhitespace(candidate) || startsWithBlockSyntax(candidate) { break }
        lines[index] = activeListContext.continuationIndent + candidate
        index += 1
      }
    }

    return lines.joined(separator: "\n")
  }

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

  private static func parseListLineContext(from line: String) -> ListLineContext? {
    let pattern = #"^(\s*)(?:[-+*]\s+(?:\[(?: |x|X)\]\s+)?|\d+[.)]\s+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsLine = line as NSString
    let range = NSRange(location: 0, length: nsLine.length)
    guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }
    let fullRange = match.range(at: 0)
    let indentRange = match.range(at: 1)
    guard fullRange.location != NSNotFound, indentRange.location != NSNotFound else { return nil }

    let indent = nsLine.substring(with: indentRange)
    let continuationWidth = max(fullRange.length, indent.count + 2)
    return ListLineContext(
      indentCount: indent.count,
      continuationIndent: String(repeating: " ", count: continuationWidth)
    )
  }

  private static func splitListParagraphSegments(_ source: String) -> [String] {
    let trimmed = source.trimmingCharacters(in: .newlines)
    guard !trimmed.isEmpty else { return [] }

    guard let regex = try? NSRegularExpression(pattern: #"\n(?:[ \t]{2,}|\n+[ \t]*)"#) else {
      return [trimmed]
    }

    let range = NSRange(trimmed.startIndex..., in: trimmed)
    var segments: [String] = []
    var lastIndex = trimmed.startIndex

    for match in regex.matches(in: trimmed, options: [], range: range) {
      guard let matchRange = Range(match.range, in: trimmed) else { continue }
      let segment = trimmed[lastIndex ..< matchRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
      if !segment.isEmpty {
        segments.append(String(segment))
      }
      lastIndex = matchRange.upperBound
    }

    let tail = trimmed[lastIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty {
      segments.append(String(tail))
    }

    return segments.isEmpty ? [trimmed] : segments
  }

  private static func shouldNormalizeLooseContinuation(
    startingAt index: Int,
    lines: [String],
    activeListContext: ListLineContext
  ) -> Bool {
    let line = lines[index]
    guard !hasLeadingWhitespace(line), !startsWithBlockSyntax(line) else { return false }

    var lookahead = index
    while lookahead < lines.count {
      let candidate = lines[lookahead]
      if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
        lookahead += 1
        continue
      }
      guard let nextListContext = parseListLineContext(from: candidate) else {
        return false
      }
      return nextListContext.indentCount <= activeListContext.indentCount + 2
    }

    return false
  }

  private static func hasLeadingWhitespace(_ line: String) -> Bool {
    guard let first = line.first else { return false }
    return first == " " || first == "\t"
  }

  private static func startsWithBlockSyntax(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    return trimmed.hasPrefix("#")
      || trimmed.hasPrefix(">")
      || trimmed.hasPrefix("|")
      || trimmed.hasPrefix("```")
      || trimmed.hasPrefix("~~~")
      || trimmed == "---"
      || trimmed == "***"
      || trimmed == "___"
  }

  private static func togglesCodeFence(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
  }

  // MARK: - Cache Machinery

  nonisolated private static func evictIfNeeded(state: inout CacheState) {
    guard state.entries.count >= maxCacheSize else { return }
    let toEvict = min(evictionBatchSize, state.entries.count)
    guard toEvict > 0 else { return }

    let keysToEvict = state.entries
      .sorted { $0.value.accessTick < $1.value.accessTick }
      .prefix(toEvict)
      .map(\.key)
    for key in keysToEvict {
      state.entries.removeValue(forKey: key)
    }
  }
}
