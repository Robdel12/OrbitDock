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
  @Test func tableParsingPreservesHeadersAndRowOrder() {
    let markdown = """
    | # | What | File |
    | --- | --- | --- |
    | 1 | Fix scheme + add Rust build step | `.github/workflows/release.yml` |
    | 2 | Add `network.client` + `automation` entitlement | `OrbitDock/OrbitDock/OrbitDock.entitlements` |
    | 3 | Strip quarantine xattr after copy | `OrbitDock/OrbitDock/Services/Server/ServerManager.swift` |
    """

    let blocks = MarkdownAttributedStringRenderer.parse(markdown)
    let table = firstTable(in: blocks)

    #expect(table != nil)
    #expect(table?.headers == ["#", "What", "File"])
    #expect(table?.rows.map { $0.first ?? "" } == ["1", "2", "3"])
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
    let blocks = MarkdownAttributedStringRenderer.parse(
      "This is a multiline paragraph check that should use readable line spacing and paragraph spacing."
    )

    let firstText = blocks.compactMap { block -> NSAttributedString? in
      if case let .text(text) = block { return text }
      return nil
    }.first
    #expect(firstText != nil)

    let paragraphStyle = firstText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect(paragraphStyle != nil)
    #expect((paragraphStyle?.lineSpacing ?? 0) >= 6)
    #expect((paragraphStyle?.paragraphSpacing ?? 0) >= 14)
  }

  @Test func listContinuationLinesRenderAsNestedBullets() {
    let markdown = """
    **What changed**
    - Question answers now carry `questionId` through the app -> websocket protocol path:
      - UI callsites: `OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView+iOS.swift:357`, `OrbitDock/OrbitDock/Views/Conversation/ConversationCollectionView+macOS.swift:884`
      - app state + connection: `OrbitDock/OrbitDock/Services/Server/ServerAppState.swift:625`, `OrbitDock/OrbitDock/Services/Server/ServerConnection.swift:589`
      - Swift wire protocol: `OrbitDock/OrbitDock/Services/Server/ServerProtocol.swift:1689`
      - Rust protocol + websocket handling: `orbitdock-server/crates/protocol/src/client.rs:51`, `orbitdock-server/crates/server/src/websocket.rs:2103`.
    """

    let blocks = MarkdownAttributedStringRenderer.parse(markdown)
    let target = blocks.compactMap { block -> NSAttributedString? in
      if case let .text(text) = block, text.string.contains("Question answers now carry") {
        return text
      }
      return nil
    }.first

    #expect(target != nil)
    #expect(target?.string.contains("path: - UI callsites") == false)
    #expect(target?.string.contains("\n\t\u{2022} UI callsites") == true)

    if let target {
      let nsText = target.string as NSString
      let parentLocation = nsText.range(of: "Question answers now carry").location
      let nestedLocation = nsText.range(of: "UI callsites").location
      #expect(parentLocation != NSNotFound)
      #expect(nestedLocation != NSNotFound)

      if parentLocation != NSNotFound, nestedLocation != NSNotFound {
        let parentStyle = target.attribute(
          .paragraphStyle,
          at: parentLocation,
          effectiveRange: nil
        ) as? NSParagraphStyle
        let nestedStyle = target.attribute(
          .paragraphStyle,
          at: nestedLocation,
          effectiveRange: nil
        ) as? NSParagraphStyle
        #expect((nestedStyle?.headIndent ?? 0) > (parentStyle?.headIndent ?? 0))
      }
    }
  }

  #if os(macOS)
    @MainActor
    @Test func nativeMarkdownTableViewUsesFlippedCoordinates() {
      let tableView = NativeMarkdownTableView(frame: CGRect(x: 0, y: 0, width: 480, height: 220))
      #expect(tableView.isFlipped)
    }
  #endif

  private func firstTable(in blocks: [MarkdownBlock]) -> (headers: [String], rows: [[String]])? {
    for block in blocks {
      if case let .table(headers, rows) = block {
        return (headers, rows)
      }
    }
    return nil
  }
}
