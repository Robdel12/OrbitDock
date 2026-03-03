import CoreGraphics
import Foundation
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif
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

  @Test func syntaxHighlighterNativeAndSwiftUIAdaptersMatchTextOutput() {
    let line = "let value = 42 // sample"
    let native = SyntaxHighlighter.highlightNativeLine(line, language: "swift")
    let swiftUI = SyntaxHighlighter.highlightLine(line, language: "swift")

    #expect(native.string == String(swiftUI.characters))
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

  @Test func inlineTableCellTextStylesCodeAndLinkRuns() {
    let attributed = MarkdownSystemParser.inlineTableCellText(
      from: "`code` and [link](https://openai.com)",
      style: .standard,
      isHeader: false
    )
    let text = attributed.string
    #expect(text.contains("code"))
    #expect(text.contains("link"))

    let linkRange = (text as NSString).range(of: "link")
    #expect(linkRange.location != NSNotFound)
    guard linkRange.location != NSNotFound else { return }
    let link = attributed.attribute(.link, at: linkRange.location, effectiveRange: nil)
    #expect(link != nil)
  }

  @Test func tableHeightExpandsForWrappedCellContent() {
    let headers = ["#", "What", "File"]
    let shortRows = [["1", "Short summary", "release.yml"]]
    let longRows = [[
      "1",
      "This is a much longer table cell intended to wrap over multiple lines in the native markdown table renderer.",
      "release.yml",
    ]]

    let shortHeight = NativeMarkdownTableView.requiredHeight(headers: headers, rows: shortRows, width: 520)
    let longHeight = NativeMarkdownTableView.requiredHeight(headers: headers, rows: longRows, width: 520)

    #expect(longHeight > shortHeight)
  }

  @Test func paragraphRenderingUsesReadableSpacing() {
    let blocks = MarkdownSystemParser.parse(
      "This is a multiline paragraph check that should use readable line spacing and paragraph spacing."
    )

    let firstText = blocks.compactMap { block -> NSAttributedString? in
      if case let .text(text) = block { return text }
      return nil
    }.first
    #expect(firstText != nil)

    let paragraphStyle = firstText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect(paragraphStyle != nil)
    #expect((paragraphStyle?.lineSpacing ?? 0) == 6)
    #expect((paragraphStyle?.paragraphSpacing ?? 0) == 16)
  }

  @Test func listContinuationLinesRemainStructured() {
    let markdown = """
    **What changed**
    - Question answers now carry `questionId` through the app -> websocket protocol path:
      - UI callsites: `OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView+iOS.swift:357`, `OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView+macOS.swift:884`
      - app state + connection: `OrbitDock/OrbitDock/Services/Server/ServerAppState.swift:625`, `OrbitDock/OrbitDock/Services/Server/ServerConnection.swift:589`
      - Swift wire protocol: `OrbitDock/OrbitDock/Services/Server/ServerProtocol.swift:1689`
      - Rust protocol + websocket handling: `orbitdock-server/crates/protocol/src/client.rs:51`, `orbitdock-server/crates/server/src/websocket.rs:2103`.
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let combinedText = blocks.compactMap { block -> String? in
      if case let .text(text) = block {
        return text.string
      }
      return nil
    }
    .joined(separator: "\n")

    #expect(combinedText.contains("Question answers now carry"))
    #expect(combinedText.contains("UI callsites"))
    #expect(combinedText.contains("Rust protocol + websocket handling"))
    #expect(combinedText.contains("path: - UI callsites") == false)
  }

  @Test func orderedListUsesSemanticIncrementingMarkers() {
    let markdown = """
    1. First item
    1. Second item
    1. Third item
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let listText = blocks.compactMap { block -> String? in
      if case let .text(text) = block { return text.string }
      return nil
    }
    .joined(separator: "\n")

    #expect(listText.contains("1.  First item"))
    #expect(listText.contains("2.  Second item"))
    #expect(listText.contains("3.  Third item"))
  }

  @Test func listMarkersUseHangingIndentFromBodyText() {
    let markdown = """
    - Bullet one with a long sentence that can wrap and should keep wrapped lines aligned with list content.
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let listText = blocks.compactMap { block -> NSAttributedString? in
      if case let .text(text) = block { return text }
      return nil
    }.first

    #expect(listText != nil)
    guard let listText else { return }

    let paragraphStyle = listText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect(paragraphStyle != nil)
    #expect((paragraphStyle?.firstLineHeadIndent ?? 0) >= 8)
    #expect((paragraphStyle?.headIndent ?? 0) > (paragraphStyle?.firstLineHeadIndent ?? 0))
  }

  @Test func nestedListItemsHaveIncreasingFirstLineIndent() {
    let markdown = """
    1. First item
    2. Trigger these:
       - update_plan
       - one request_user_input flow
    3. Confirm tool rows
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let listText = blocks.compactMap { block -> NSAttributedString? in
      if case let .text(text) = block { return text }
      return nil
    }.first

    #expect(listText != nil)
    guard let listText else { return }

    let ns = listText.string as NSString

    // Find a top-level numbered item and a nested bullet
    let topRange = ns.range(of: "1.")
    let nestedRange = ns.range(of: "•")
    #expect(topRange.location != NSNotFound)
    #expect(nestedRange.location != NSNotFound)
    guard topRange.location != NSNotFound, nestedRange.location != NSNotFound else { return }

    let topStyle = listText.attribute(
      .paragraphStyle,
      at: topRange.location,
      effectiveRange: nil
    ) as? NSParagraphStyle
    let nestedStyle = listText.attribute(
      .paragraphStyle,
      at: nestedRange.location,
      effectiveRange: nil
    ) as? NSParagraphStyle

    #expect(topStyle != nil)
    #expect(nestedStyle != nil)
    #expect(
      (nestedStyle?.firstLineHeadIndent ?? 0) > (topStyle?.firstLineHeadIndent ?? 0),
      "Nested bullets should have a larger firstLineHeadIndent than top-level items"
    )
  }

  @Test func listContinuationParagraphSpacingStaysAttachedToItem() {
    let markdown = """
    - Bullet two with continuation paragraph:

      This continuation should stay attached to bullet two.
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let listText = blocks.compactMap { block -> NSAttributedString? in
      if case let .text(text) = block { return text }
      return nil
    }.first

    #expect(listText != nil)
    guard let listText else { return }
    let ns = listText.string as NSString

    let markerRange = ns.range(of: "•  Bullet two with continuation paragraph:")
    let continuationRange = ns.range(of: "This continuation should stay attached to bullet two.")
    #expect(markerRange.location != NSNotFound)
    #expect(continuationRange.location != NSNotFound)
    guard markerRange.location != NSNotFound, continuationRange.location != NSNotFound else { return }

    let markerStyle = listText.attribute(
      .paragraphStyle,
      at: markerRange.location,
      effectiveRange: nil
    ) as? NSParagraphStyle
    let continuationStyle = listText.attribute(
      .paragraphStyle,
      at: continuationRange.location,
      effectiveRange: nil
    ) as? NSParagraphStyle

    #expect(markerStyle != nil)
    #expect(continuationStyle != nil)
    #expect((continuationStyle?.paragraphSpacing ?? 0) <= (markerStyle?.paragraphSpacing ?? 0))
    #expect((continuationStyle?.firstLineHeadIndent ?? 0) >= (markerStyle?.firstLineHeadIndent ?? 0))
  }

  @Test func taskListUsesCheckboxGlyphsAndPreservesContinuationParagraphs() {
    let markdown = """
    - [x] Completed task

      This continuation paragraph should remain attached to the same task item.
    - [ ] Open task
    """

    let blocks = MarkdownSystemParser.parse(markdown)
    let listText = blocks.compactMap { block -> String? in
      if case let .text(text) = block { return text.string }
      return nil
    }
    .joined(separator: "\n")

    #expect(listText.contains("☑  Completed task"))
    #expect(listText.contains("☐  Open task"))
    #expect(listText.contains("[x] Completed task") == false)
    #expect(listText.contains("[ ] Open task") == false)
    #expect(listText.contains("continuation paragraph should remain attached"))
    #expect(listText.contains("task.This continuation") == false)
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
    #expect(quote?.contains("Second quote paragraph with inline code.") == true)
    #expect(quote?.contains("Quoted item one") == true)
    #expect(quote?.contains("Quoted item two") == true)
    #expect(quote?.contains("> Quoted item one") == false)
    #expect(quote?.contains("> Quoted ordered one") == false)
    #expect(quote?.contains("inline code.Quoted item one") == false)
    #expect(quote?.contains("Quoted item oneQuoted item two") == false)
  }

  #if os(macOS)
    @MainActor
    @Test func nativeMarkdownTableViewUsesFlippedCoordinates() {
      let tableView = NativeMarkdownTableView(frame: CGRect(x: 0, y: 0, width: 480, height: 220))
      #expect(tableView.isFlipped)
    }
  #endif

  @Test func parserPreservesHardLineBreaksWithinParagraphText() {
    let blocks = MarkdownSystemParser.parse("Line one  \nLine two")
    let text = firstText(in: blocks)?.string ?? ""
    #expect(text.contains("Line one\nLine two"))
  }

  @Test func parserPreservesImageAltTextAndInlineHTMLLiterals() {
    let markdown = """
    ![Architecture diagram](https://example.com/diagram.png)

    Use <kbd>cmd+k</kbd> to open search.
    """
    let blocks = MarkdownSystemParser.parse(markdown)
    let combined = blocks.compactMap { block -> String? in
      if case let .text(text) = block { return text.string }
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

  @Test func headingLevelsFourThroughSixUseDescendingFontSizes() {
    let markdown = """
    #### H4

    ##### H5

    ###### H6
    """
    let blocks = MarkdownSystemParser.parse(markdown, style: .standard)
    let textBlocks = blocks.compactMap { block -> NSAttributedString? in
      if case let .text(text) = block { return text }
      return nil
    }

    #expect(textBlocks.count >= 3)
    guard textBlocks.count >= 3 else { return }

    let h4 = fontPointSize(in: textBlocks[0]) ?? 0
    let h5 = fontPointSize(in: textBlocks[1]) ?? 0
    let h6 = fontPointSize(in: textBlocks[2]) ?? 0

    #expect(h4 >= h5)
    #expect(h5 >= h6)
    #expect(h4 > 0)
  }

  @Test func boldTextAppliesBoldFontWeight() {
    let blocks = MarkdownSystemParser.parse("This has **bold** text.")
    let text = firstText(in: blocks)
    #expect(text != nil)
    guard let text else { return }

    let font = fontAt(substring: "bold", in: text)
    #expect(font != nil)
    #if os(macOS)
      #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #else
      #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    #endif
  }

  @Test func italicTextAppliesItalicFontTrait() {
    let blocks = MarkdownSystemParser.parse("This has *italic* text.")
    let text = firstText(in: blocks)
    #expect(text != nil)
    guard let text else { return }

    let font = fontAt(substring: "italic", in: text)
    #expect(font != nil)
    #if os(macOS)
      #expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    #else
      #expect(font?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
    #endif
  }

  @Test func strikethroughTextAppliesStrikethroughAttribute() {
    let blocks = MarkdownSystemParser.parse("This has ~~struck~~ text.")
    let text = firstText(in: blocks)
    #expect(text != nil)
    guard let text else { return }

    let range = (text.string as NSString).range(of: "struck")
    #expect(range.location != NSNotFound)
    guard range.location != NSNotFound else { return }

    let strikethrough = text.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int
    #expect(strikethrough == NSUnderlineStyle.single.rawValue)
  }

  @Test func boldItalicCombinationAppliesBothTraits() {
    let blocks = MarkdownSystemParser.parse("This has ***bolditalic*** text.")
    let text = firstText(in: blocks)
    #expect(text != nil)
    guard let text else { return }

    let font = fontAt(substring: "bolditalic", in: text)
    #expect(font != nil)
    #if os(macOS)
      let traits = font?.fontDescriptor.symbolicTraits ?? []
      #expect(traits.contains(.bold))
      #expect(traits.contains(.italic))
    #else
      let traits = font?.fontDescriptor.symbolicTraits ?? []
      #expect(traits.contains(.traitBold))
      #expect(traits.contains(.traitItalic))
    #endif
  }

  @Test func thinkingStyleUsesSmallerHeadingAndBodyTypography() {
    let markdown = """
    ## Heading

    Body text for comparison.
    """
    let standardBlocks = MarkdownSystemParser.parse(markdown, style: .standard)
    let thinkingBlocks = MarkdownSystemParser.parse(markdown, style: .thinking)

    guard let standardHeading = firstText(in: standardBlocks),
          let thinkingHeading = firstText(in: thinkingBlocks)
    else {
      #expect(Bool(false))
      return
    }

    let standardSize = fontPointSize(in: standardHeading) ?? 0
    let thinkingSize = fontPointSize(in: thinkingHeading) ?? 0
    #expect(thinkingSize < standardSize)
    #expect(standardSize == 20, "Standard H2 should be 20pt")
    #expect(thinkingSize == 16, "Thinking H2 should be 16pt")
  }

  @Test func thinkingModeHeadingsFormDistinctHierarchy() {
    let markdown = """
    # H1

    ## H2

    ### H3

    Body text.
    """
    let blocks = MarkdownSystemParser.parse(markdown, style: .thinking)
    let textBlocks = blocks.compactMap { block -> NSAttributedString? in
      if case let .text(text) = block { return text }
      return nil
    }

    #expect(textBlocks.count >= 4)
    guard textBlocks.count >= 4 else { return }

    let h1Size = fontPointSize(in: textBlocks[0]) ?? 0
    let h2Size = fontPointSize(in: textBlocks[1]) ?? 0
    let h3Size = fontPointSize(in: textBlocks[2]) ?? 0
    let bodySize = fontPointSize(in: textBlocks[3]) ?? 0

    #expect(h1Size > h2Size, "H1 (\(h1Size)) should be larger than H2 (\(h2Size))")
    #expect(h2Size > h3Size, "H2 (\(h2Size)) should be larger than H3 (\(h3Size))")
    #expect(h3Size > bodySize, "H3 (\(h3Size)) should be larger than body (\(bodySize))")

    #expect(h1Size == 18, "H1 thinking should be 18pt, got \(h1Size)")
    #expect(h2Size == 16, "H2 thinking should be 16pt, got \(h2Size)")
    #expect(h3Size == 14, "H3 thinking should be 14pt, got \(h3Size)")
    #expect(bodySize == 13, "Body thinking should be 13pt, got \(bodySize)")
  }

  @Test func interBlockSpacingUsesGridAlignedValues() {
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .codeBlock, style: .standard) == 12)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .table, style: .standard) == 12)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .blockquote, style: .standard) == 12)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .codeBlock, style: .thinking) == 8)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .thematicBreak, style: .standard) == 16)
    #expect(MarkdownLayoutMetrics.verticalMargin(for: .thematicBreak, style: .thinking) == 8)
  }

  private func firstTable(in blocks: [MarkdownBlock]) -> (headers: [String], rows: [[String]])? {
    for block in blocks {
      if case let .table(headers, rows) = block {
        return (headers, rows)
      }
    }
    return nil
  }

  private func firstText(in blocks: [MarkdownBlock]) -> NSAttributedString? {
    for block in blocks {
      if case let .text(text) = block { return text }
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

  private func fontAt(substring: String, in text: NSAttributedString) -> PlatformFont? {
    let range = (text.string as NSString).range(of: substring)
    guard range.location != NSNotFound else { return nil }
    return text.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
  }

  private func fontPointSize(in text: NSAttributedString) -> CGFloat? {
    guard text.length > 0 else { return nil }
    #if os(macOS)
      return (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
    #else
      return (text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize
    #endif
  }

  private func firstBlockquote(in blocks: [MarkdownBlock]) -> String? {
    for block in blocks {
      if case let .blockquote(text) = block {
        return text.string
      }
    }
    return nil
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
