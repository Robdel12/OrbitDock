import Foundation
@testable import OrbitDock
import Testing

struct MarkdownRenderSegmentProjectorTests {
  @Test func proseCodeProseSplitsIntoThreeSegments() {
    let segments = project(
      """
      First paragraph.

      ```swift
      let value = 1
      ```

      Second paragraph.
      """
    )

    #expect(segments.count == 3)
    #expect(kinds(in: segments) == ["prose", "codeBlock", "prose"])

    guard case let .prose(first) = segments[0],
          case let .codeBlock(code) = segments[1],
          case let .prose(last) = segments[2]
    else {
      Issue.record("Expected prose / codeBlock / prose segments.")
      return
    }

    #expect(first.sourceBlockRange == 0..<1)
    #expect(first.blocks.count == 1)
    #expect(code.sourceBlockRange == 1..<2)
    #expect(code.language == "swift")
    #expect(last.sourceBlockRange == 2..<3)
    #expect(last.blocks.count == 1)
  }

  @Test func headingsAndListsMergeIntoOneProseSegment() {
    let segments = project(
      """
      # Overview

      - First item
      - Second item
      """
    )

    #expect(segments.count == 1)

    guard case let .prose(prose) = segments.first else {
      Issue.record("Expected a single prose segment.")
      return
    }

    #expect(prose.sourceBlockRange == 0..<2)
    #expect(prose.blocks.count == 2)

    if case .heading = prose.blocks[0] {
      // good
    } else {
      Issue.record("Expected the first prose block to be a heading.")
    }

    if case .list = prose.blocks[1] {
      // good
    } else {
      Issue.record("Expected the second prose block to be a list.")
    }
  }

  @Test func tablesSplitProseSegments() {
    let segments = project(
      """
      Paragraph before.

      | Name | Value |
      | --- | --- |
      | One | Two |

      Paragraph after.
      """
    )

    #expect(segments.count == 3)
    #expect(kinds(in: segments) == ["prose", "table", "prose"])

    guard case let .table(table) = segments[1] else {
      Issue.record("Expected the middle segment to be a table.")
      return
    }

    #expect(table.sourceBlockRange == 1..<2)
    #expect(table.headers == ["Name", "Value"])
    #expect(table.rows.first == ["One", "Two"])
  }

  @Test func thematicBreakSplitsProseSegments() {
    let segments = project(
      """
      Before the break.

      ---

      After the break.
      """
    )

    #expect(segments.count == 3)
    #expect(kinds(in: segments) == ["prose", "thematicBreak", "prose"])

    guard case let .thematicBreak(breakSegment) = segments[1] else {
      Issue.record("Expected the middle segment to be a thematic break.")
      return
    }

    #expect(breakSegment.sourceBlockRange == 1..<2)
    #expect(breakSegment.identity.kind.rawValue == "thematicBreak")
  }

  @Test func identitiesAreStableFromSourceBlockPositions() {
    let segments = project(
      """
      One.

      Two.

      ```swift
      let x = 1
      ```
      """
    )

    #expect(segments.map(\.startBlockIndex) == [0, 2])
    #expect(segments.map { $0.identity.kind.rawValue } == ["prose", "codeBlock"])
  }

  private func project(_ markdown: String) -> [MarkdownRenderSegment] {
    MarkdownRenderSegmentProjector.project(MarkdownSystemParser.parse(markdown))
  }

  private func kinds(in segments: [MarkdownRenderSegment]) -> [String] {
    segments.map { $0.kind.rawValue }
  }
}
