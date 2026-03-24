import Foundation
import SwiftUI
@testable import OrbitDock
import Testing

struct MarkdownProseAttributedStringBuilderTests {
  private struct FontDescriptor: Equatable {
    let size: Double?
    let weight: String?
    let design: String?
  }

  @Test func proseBuilderRendersHeadingsWithStrongerTypography() {
    let blocks: [MarkdownBlock] = [
      .heading(level: 1, text: "A Clear Heading"),
      .text("Body paragraph.")
    ]

    let attributed = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .standard)
    #expect(String(attributed.characters) == "A Clear Heading\nBody paragraph.")

    let headingFont = firstFontDescriptor(in: attributed, matching: "A Clear Heading")
    let bodyFont = firstFontDescriptor(in: attributed, matching: "Body paragraph.")

    #expect(headingFont != nil)
    #expect(bodyFont != nil)
    #expect(headingFont != bodyFont)
  }

  @Test func proseBuilderPreservesLinksAndInlineCodeStyling() {
    let blocks: [MarkdownBlock] = [
      .text("Visit [OpenAI](https://openai.com) and use `cmd+k`.")
    ]

    let attributed = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .standard)

    let links = links(in: attributed)
    #expect(links.contains("https://openai.com"))

    let codeFont = firstFontDescriptor(in: attributed, matching: "cmd+k")
    let bodyFont = firstFontDescriptor(in: attributed, matching: "Visit")
    let codeColor = firstForegroundColorDescription(in: attributed, matching: "cmd+k")
    let bodyColor = firstForegroundColorDescription(in: attributed, matching: "Visit")

    #expect(codeFont?.design == "SwiftUI.Font.Design.monospaced")
    #expect(bodyFont?.design == nil)
    #expect(codeColor != nil)
    #expect(bodyColor != nil)
    #expect(codeColor != bodyColor)
  }

  @Test func proseBuilderRendersNestedListsAndContinuationParagraphs() {
    let blocks: [MarkdownBlock] = [
      .list([
        ListItem(
          marker: .number(1),
          content: "First item with [link](https://example.com)",
          continuation: ["Continuation paragraph with `inline code`."],
          children: [
            ListItem(
              marker: .bullet,
              content: "Nested child item",
              continuation: [],
              children: []
            )
          ]
        ),
        ListItem(
          marker: .checked,
          content: "Second item",
          continuation: [],
          children: []
        )
      ])
    ]

    let attributed = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .standard)
    let rendered = String(attributed.characters)

    #expect(rendered.contains("1. First item with link"))
    #expect(rendered.contains("Continuation paragraph with inline code."))
    #expect(rendered.contains("• Nested child item"))
    #expect(rendered.contains("\n\u{00A0}\u{00A0}☑ Second item"))

    let links = links(in: attributed)
    #expect(links.contains("https://example.com"))
  }

  @Test func proseBuilderRendersBlockquotesAsQuotedText() {
    let blocks: [MarkdownBlock] = [
      .blockquote("First quote line.\n\nSecond quote line with [link](https://openai.com).")
    ]

    let attributed = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .thinking)
    let rendered = String(attributed.characters)

    #expect(rendered.contains("▎ First quote line."))
    #expect(rendered.contains("▎ Second quote line with link."))
    #expect(!rendered.contains("\n▎ \n"))

    let links = links(in: attributed)
    #expect(links.contains("https://openai.com"))
  }

  @Test func proseBuilderAppliesStyleSpecificTypography() {
    let blocks: [MarkdownBlock] = [
      .heading(level: 2, text: "Section"),
      .text("Body")
    ]

    let standard = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .standard)
    let thinking = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .thinking)

    let standardHeadingFont = firstFontDescriptor(in: standard, matching: "Section")
    let thinkingHeadingFont = firstFontDescriptor(in: thinking, matching: "Section")
    let standardBodyFont = firstFontDescriptor(in: standard, matching: "Body")
    let thinkingBodyFont = firstFontDescriptor(in: thinking, matching: "Body")

    #expect(standardHeadingFont != nil)
    #expect(thinkingHeadingFont != nil)
    #expect(standardBodyFont != nil)
    #expect(thinkingBodyFont != nil)
    #expect(standardHeadingFont?.size != thinkingHeadingFont?.size)
    #expect(standardBodyFont?.size != thinkingBodyFont?.size)
  }

  @Test func proseBuilderKeepsHeadingTightToFollowingParagraph() {
    let blocks: [MarkdownBlock] = [
      .heading(level: 2, text: "Section Heading"),
      .text("The body should start right under the heading.")
    ]

    let attributed = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .standard)
    let rendered = String(attributed.characters)

    #expect(rendered == "Section Heading\nThe body should start right under the heading.")
  }

  @Test func proseBuilderUsesCompactSpacingAroundLists() {
    let blocks: [MarkdownBlock] = [
      .text("Intro paragraph."),
      .list([
        ListItem(marker: .bullet, content: "First", continuation: [], children: []),
        ListItem(marker: .bullet, content: "Second", continuation: [], children: [])
      ]),
      .text("Outro paragraph.")
    ]

    let attributed = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .standard)
    let rendered = String(attributed.characters)

    #expect(rendered == "Intro paragraph.\n\n\u{00A0}\u{00A0}• First\n\u{00A0}\u{00A0}• Second\n\nOutro paragraph.")
  }

  @Test func proseBuilderUsesSecondaryColorForDeeperHeadings() {
    let blocks: [MarkdownBlock] = [
      .heading(level: 3, text: "Subsection")
    ]

    let attributed = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .standard)
    let colorDescription = firstForegroundColorDescription(in: attributed, matching: "Subsection")

    #expect(colorDescription != nil)
    #expect(colorDescription == normalizedDescription(Color.textSecondary))
  }

  @Test func repeatedBuildsStayStableAcrossCacheHits() {
    let blocks: [MarkdownBlock] = [
      .text("Repeated `cache` hit"),
      .blockquote("Second fragment.")
    ]

    let first = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .standard)
    let second = MarkdownProseAttributedStringBuilder.build(from: blocks, style: .standard)

    #expect(String(first.characters) == String(second.characters))
    #expect(first.runs.count == second.runs.count)
    #expect(first.runs.map { String(describing: $0.font) } == second.runs.map { String(describing: $0.font) })
  }

  @Test func inlineMarkdownForegroundColorDoesNotLeakAcrossCacheHits() {
    let first = MarkdownProseAttributedStringBuilder.inlineMarkdown(
      "Cache me",
      style: .standard,
      foregroundColor: .red
    )
    let second = MarkdownProseAttributedStringBuilder.inlineMarkdown(
      "Cache me",
      style: .standard,
      foregroundColor: .blue
    )

    #expect(firstForegroundColorDescription(in: first, matching: "Cache me") != firstForegroundColorDescription(in: second, matching: "Cache me"))
  }

  private func links(in attributed: AttributedString) -> Set<String> {
    Set(attributed.runs.compactMap { $0.link?.absoluteString })
  }

  private func firstForegroundColorDescription(in attributed: AttributedString, matching text: String) -> String? {
    for run in attributed.runs {
      let runText = String(attributed[run.range].characters)
      guard runText.contains(text) else { continue }
      return optionalNormalizedDescription(run.foregroundColor as Any)
    }
    return nil
  }

  private func firstFontDescriptor(in attributed: AttributedString, matching text: String) -> FontDescriptor? {
    for run in attributed.runs {
      let runText = String(attributed[run.range].characters)
      guard runText.contains(text) else { continue }
      guard let font = run.font else { return nil }
      return FontDescriptor(
        size: doubleValue(named: "size", in: font),
        weight: labeledDescription(named: "weight", in: font),
        design: labeledDescription(named: "design", in: font)
      )
    }
    return nil
  }

  private func doubleValue(named label: String, in value: Any) -> Double? {
    guard let labeledValue = labeledValue(named: label, in: value) else { return nil }
    if let value = labeledValue as? Double {
      return value
    }
    if let value = labeledValue as? CGFloat {
      return Double(value)
    }
    return nil
  }

  private func labeledDescription(named label: String, in value: Any) -> String? {
    guard let labeledValue = labeledValue(named: label, in: value) else { return nil }
    return optionalNormalizedDescription(labeledValue)
  }

  private func labeledValue(named label: String, in value: Any) -> Any? {
    let mirror = Mirror(reflecting: value)
    for child in mirror.children {
      if child.label == label {
        return child.value
      }
      if let nested = labeledValue(named: label, in: child.value) {
        return nested
      }
    }
    return nil
  }

  private func normalizedDescription(_ value: Any) -> String {
    let description = String(describing: value)
    guard description.hasPrefix("Optional("), description.hasSuffix(")") else {
      return description
    }
    return String(description.dropFirst("Optional(".count).dropLast())
  }

  private func optionalNormalizedDescription(_ value: Any) -> String? {
    let description = normalizedDescription(value)
    return description == "nil" ? nil : description
  }
}
