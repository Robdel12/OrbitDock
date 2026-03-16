//
//  MarkdownContentView.swift
//  OrbitDock
//
//  Drop-in SwiftUI replacement for MarkdownContentRepresentable.
//  No availableWidth, no height measurement, no NSViewRepresentable.
//
//  Large content (>50 lines or >8K chars) is truncated before parsing
//  to prevent SwiftUI from choking on massive Text views. Users can
//  expand inline to see the full content.
//

import SwiftUI

struct MarkdownContentView: View {
  let content: String
  let style: ContentStyle

  private static let collapseLineThreshold = 50
  private static let collapsedLineCount = 20
  private static let maxCharacterCount = 8_000

  @State private var isExpanded = false

  private var lines: [Substring] {
    content.split(separator: "\n", omittingEmptySubsequences: false)
  }

  private var shouldCollapse: Bool {
    lines.count > Self.collapseLineThreshold || content.count > Self.maxCharacterCount
  }

  private var visibleContent: String {
    guard shouldCollapse, !isExpanded else { return content }

    if lines.count > Self.collapseLineThreshold {
      return lines.prefix(Self.collapsedLineCount).joined(separator: "\n")
    }

    // Character-based truncation (few lines but very long)
    let end = content.index(
      content.startIndex,
      offsetBy: Self.maxCharacterCount,
      limitedBy: content.endIndex
    ) ?? content.endIndex
    return String(content[..<end])
  }

  var body: some View {
    let blocks = MarkdownSystemParser.parse(visibleContent, style: style)
    if !blocks.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        MarkdownBlockView(blocks: blocks, style: style)

        if shouldCollapse {
          Button {
            isExpanded.toggle()
          } label: {
            let hiddenCount = lines.count - Self.collapsedLineCount
            Text(isExpanded ? "Show less" : "Show \(hiddenCount) more lines")
              .font(.system(size: TypeScale.meta, weight: .medium))
              .foregroundStyle(Color.textTertiary)
              .padding(.top, 6)
          }
          .buttonStyle(.plain)
          .transaction { $0.animation = nil }
        }
      }
    }
  }
}
