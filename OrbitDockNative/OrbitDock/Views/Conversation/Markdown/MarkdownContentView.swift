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
  var isStreaming: Bool = false

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

  private var streamingProjection: MarkdownStreamingProjection {
    MarkdownStreamingProjection.make(content: visibleContent, isStreaming: isStreaming)
  }

  var body: some View {
    let stablePrefix = streamingProjection.stablePrefix
    let streamingTail = streamingProjection.streamingTail
    let blocks = MarkdownSystemParser.parse(stablePrefix, style: style)

    if !blocks.isEmpty || !streamingTail.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        if !blocks.isEmpty {
          MarkdownBlockView(blocks: blocks, style: style)
        }

        if !streamingTail.isEmpty {
          Text(verbatim: streamingTail)
            .foregroundStyle(tailForegroundStyle)
            .lineSpacing(MarkdownTypography.bodyLineSpacing(style: style))
            .font(MarkdownTypography.bodyFont(style: style))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }

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

  private var tailForegroundStyle: Color {
    switch style {
      case .standard:
        .textPrimary
      case .thinking:
        .textSecondary
    }
  }
}
