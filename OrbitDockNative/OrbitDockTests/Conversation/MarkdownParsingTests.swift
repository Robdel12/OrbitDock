import CoreGraphics
import Foundation
@testable import OrbitDock
import Testing

struct MarkdownParsingTests {
  @Test func parserReturnsNoBlocksForWhitespaceOnlyContent() {
    #expect(MarkdownSystemParser.parse("   \n\t  ").isEmpty)
  }

  @Test func systemMarkdownLinksBareAndExplicitURLs() throws {
    let markdown = "Visit https://example.com and [OpenAI](https://openai.com)."
    let attributed = try AttributedString(markdown: markdown)

    let links = links(in: attributed)
    #expect(links.contains("https://example.com"))
    #expect(links.contains("https://openai.com"))
  }

  @Test func systemMarkdownEmitsTableAndCodeBlockPresentationIntents() throws {
    let markdown = """
    | A | B |
    | --- | --- |
    | 1 | 2 |

    ```swift
    let x = 1
    ```
    """
    let attributed = try AttributedString(markdown: markdown)
    let intentDump = presentationIntentDump(in: attributed)

    #expect(intentDump.contains("table"))
    #expect(intentDump.contains("codeBlock"))
  }

  @Test func systemMarkdownTaskListMarkersAreLiteralText() throws {
    let markdown = """
    - [x] done
    - [ ] open
    """
    let attributed = try AttributedString(markdown: markdown)
    let text = String(attributed.characters)

    #expect(text.contains("[x] done"))
    #expect(text.contains("[ ] open"))
  }

  @Test func languageAliasNormalizationIsShared() {
    #expect(MarkdownLanguage.normalize("js") == "javascript")
    #expect(MarkdownLanguage.normalize("tsx") == "typescript")
    #expect(MarkdownLanguage.normalize("zsh") == "bash")
    #expect(MarkdownLanguage.normalize("PY") == "python")
    #expect(MarkdownLanguage.normalize("yml") == "yaml")
    #expect(MarkdownLanguage.normalize(nil) == nil)
    #expect(MarkdownLanguage.normalize("   ") == nil)
  }

  @Test func codeFenceLanguageIsNormalizedInParserOutput() {
    let markdown = """
    ```js
    console.log("hello")
    ```
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let language = blocks.compactMap { block -> String? in
      if case let .codeBlock(lang, _) = block { return lang }
      return nil
    }.first

    #expect(language == "javascript")
  }

  @Test func tableParsingPreservesHeadersAndRowOrder() {
    let markdown = """
    | # | What | File |
    | --- | --- | --- |
    | 1 | Fix scheme + add Rust build step | `.github/workflows/release.yml` |
    | 2 | Add `network.client` + `automation` entitlement | `OrbitDock/OrbitDock/OrbitDock.entitlements` |
    | 3 | Strip quarantine xattr after copy | `OrbitDock/OrbitDock/Services/Server/ServerManager.swift` |
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let table = firstTable(in: blocks)

    #expect(table != nil)
    #expect(table?.headers == ["#", "What", "File"])
    #expect(table?.rows.map { $0.first ?? "" } == ["1", "2", "3"])
  }

  @Test func tableParsingPreservesInlineMarkdownCellSource() {
    let markdown = """
    | Name | Notes |
    | --- | --- |
    | OrbitDock | `inline code` |
    | OpenAI | [link](https://openai.com) |
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let table = firstTable(in: blocks)
    #expect(table != nil)

    let notesColumn = table?.rows.compactMap { row in
      row.count > 1 ? row[1] : nil
    } ?? []
    #expect(notesColumn.contains("`inline code`"))
    #expect(notesColumn.contains("[link](https://openai.com)"))
  }

  @Test func tableBlocksAreProducedForMarkdownTables() {
    let markdown = """
    | # | What | File |
    |---|------|------|
    | 1 | Short summary | release.yml |
    """
    let blocks = MarkdownSystemParser.parse(markdown)
    let hasTable = blocks.contains { block in
      if case .table = block { return true }
      return false
    }
    #expect(hasTable)
  }

  @Test func listContinuationLinesRemainStructured() {
    let markdown = """
    **What changed**
    - Question answers now carry `questionId` through the app -> websocket protocol path:
      - UI callsites: `OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView+iOS.swift:357`, `OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView+macOS.swift:884`
      - session store + connection: `OrbitDock/OrbitDock/Services/Server/SessionStore.swift:108`, `OrbitDock/OrbitDock/Services/Server/ServerConnection.swift:197`
      - Swift wire protocol: `OrbitDock/OrbitDock/Services/Server/Protocol/ClientToServerMessage.swift:13`
      - Rust protocol + websocket handling: `orbitdock-server/crates/protocol/src/client.rs:51`, `orbitdock-server/crates/server/src/websocket.rs:2103`.
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let combinedText = blocks.compactMap { block -> String? in
      if case let .text(text) = block {
        return text
      }
      return nil
    }
    .joined(separator: "\n")

    #expect(combinedText.contains("Question answers now carry"))
    #expect(combinedText.contains("UI callsites"))
    #expect(combinedText.contains("Rust protocol + websocket handling"))
  }

  @Test func orderedListUsesSemanticIncrementingMarkers() {
    let markdown = """
    1. First item
    1. Second item
    1. Third item
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let listText = blocks.compactMap { block -> String? in
      if case let .text(text) = block { return text }
      return nil
    }
    .joined(separator: "\n")

    #expect(listText.contains("1.  First item"))
    #expect(listText.contains("2.  Second item"))
    #expect(listText.contains("3.  Third item"))
  }

  @Test func taskListUsesCheckboxGlyphsAndPreservesContinuationParagraphs() {
    let markdown = """
    - [x] Completed task

      This continuation paragraph should remain attached to the same task item.
    - [ ] Open task
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let listText = blocks.compactMap { block -> String? in
      if case let .text(text) = block { return text }
      return nil
    }
    .joined(separator: "\n")

    #expect(listText.contains("☑  Completed task"))
    #expect(listText.contains("☐  Open task"))
    #expect(listText.contains("[x] Completed task") == false)
    #expect(listText.contains("[ ] Open task") == false)
    #expect(listText.contains("continuation paragraph should remain attached"))
  }

  @Test func blockquotePreservesParagraphsAndNestedListBoundaries() {
    let markdown = """
    > First quote paragraph.
    >
    > Second quote paragraph with `inline code`.
    >
    > - Quoted item one
    > - Quoted item two
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let quote = firstBlockquote(in: blocks)

    #expect(quote != nil)
    #expect(quote?.contains("First quote paragraph.") == true)
    #expect(quote?.contains("Second quote paragraph") == true)
    #expect(quote?.contains("inline code") == true)
    #expect(quote?.contains("Quoted item one") == true)
    #expect(quote?.contains("Quoted item two") == true)
  }

  @Test func tableBlockContainsExpectedHeaders() {
    let markdown = """
    | Name | Value |
    |------|-------|
    | key  | val   |
    """
    let blocks = MarkdownSystemParser.parse(markdown)
    let table = blocks.compactMap { block -> (headers: [String], rows: [[String]])? in
      if case let .table(h, r) = block { return (h, r) }
      return nil
    }.first
    #expect(table?.headers == ["Name", "Value"])
    #expect(table?.rows.first == ["key", "val"])
  }

  @Test func parserPreservesImageAltTextAndInlineHTMLLiterals() {
    let markdown = """
    ![Architecture diagram](https://example.com/diagram.png)

    Use <kbd>cmd+k</kbd> to open search.
    """
    let blocks = MarkdownSystemParser.parse(markdown)
    let combined = blocks.compactMap { block -> String? in
      if case let .text(text) = block { return text }
      return nil
    }
    .joined(separator: "\n")

    #expect(combined.contains("Architecture diagram"))
    #expect(combined.contains("<kbd>cmd+k</kbd>"))
  }

  @Test func parserEmitsMixedBlockSequenceDeterministically() {
    let markdown = """
    # Heading

    Body paragraph.

    > Quoted paragraph.

    - Item one
    - Item two

    ---

    ```swift
    let x = 1
    ```

    | A | B |
    | --- | --- |
    | 1 | 2 |
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let blockKinds = blocks.map { blockKindName($0) }

    #expect(blockKinds.contains("text"))
    #expect(blockKinds.contains("blockquote"))
    #expect(blockKinds.contains("thematicBreak"))
    #expect(blockKinds.contains("codeBlock"))
    #expect(blockKinds.contains("table"))
  }

  @Test func interBlockSpacingUsesGridAlignedValues() {
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .codeBlock, style: .standard) == 12)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .table, style: .standard) == 12)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .blockquote, style: .standard) == 12)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .codeBlock, style: .thinking) == 8)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .thematicBreak, style: .standard) == 16)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .thematicBreak, style: .thinking) == 8)
  }

  // MARK: - New tests

  @Test func headingsH1ThroughH3RenderAsBold() {
    let markdown = """
    # First

    ## Second

    ### Third
    """
    let blocks = MarkdownSystemParser.parse(markdown)
    let textBlocks = blocks.compactMap { block -> String? in
      if case let .text(text) = block { return text }
      return nil
    }

    #expect(textBlocks.count >= 3)
    guard textBlocks.count >= 3 else { return }

    #expect(textBlocks[0] == "**First**")
    #expect(textBlocks[1] == "**Second**")
    #expect(textBlocks[2] == "**Third**")
  }

  @Test func headingsH4ThroughH6RenderAsPlainText() {
    let markdown = """
    #### H4

    ##### H5

    ###### H6
    """
    let blocks = MarkdownSystemParser.parse(markdown)
    let textBlocks = blocks.compactMap { block -> String? in
      if case let .text(text) = block { return text }
      return nil
    }

    #expect(textBlocks.count >= 3)
    guard textBlocks.count >= 3 else { return }

    #expect(textBlocks[0] == "H4")
    #expect(textBlocks[1] == "H5")
    #expect(textBlocks[2] == "H6")
  }

  @Test func parserOutputIsIdenticalAcrossStyles() {
    let markdown = """
    # Heading

    Body paragraph.

    > Quote.

    - Item one
    - Item two
    """
    let standard = MarkdownSystemParser.parse(markdown, style: .standard)
    let thinking = MarkdownSystemParser.parse(markdown, style: .thinking)

    #expect(standard == thinking)
  }

  // MARK: - Helpers

  private func firstTable(in blocks: [MarkdownBlock]) -> (headers: [String], rows: [[String]])? {
    for block in blocks {
      if case let .table(headers, rows) = block {
        return (headers, rows)
      }
    }
    return nil
  }

  private func firstBlockquote(in blocks: [MarkdownBlock]) -> String? {
    for block in blocks {
      if case let .blockquote(text) = block { return text }
    }
    return nil
  }

  private func blockKindName(_ block: MarkdownBlock) -> String {
    switch block {
      case .text: "text"
      case .codeBlock: "codeBlock"
      case .blockquote: "blockquote"
      case .table: "table"
      case .thematicBreak: "thematicBreak"
    }
  }

  private func links(in attributed: AttributedString) -> Set<String> {
    Set(attributed.runs.compactMap { $0.link?.absoluteString })
  }

  private func presentationIntentDump(in attributed: AttributedString) -> String {
    attributed.runs
      .map { String(describing: $0.presentationIntent) }
      .joined(separator: "\n")
  }
}
