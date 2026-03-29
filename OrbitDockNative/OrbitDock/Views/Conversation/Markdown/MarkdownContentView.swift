//
//  MarkdownContentView.swift
//  OrbitDock
//
//  Thin composition layer for conversation markdown rendering.
//  The heavy lifting now lives in the segment projector and prose builder.
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

  private var collapseButtonTitle: String {
    guard !isExpanded else { return "Show less" }

    if lines.count > Self.collapseLineThreshold {
      let hiddenCount = max(lines.count - Self.collapsedLineCount, 0)
      return "Show \(hiddenCount) more lines"
    }

    return "Show more"
  }

  private var renderSegments: [MarkdownRenderSegment] {
    let stablePrefix = streamingProjection.stablePrefix
    let cached = MarkdownRenderSegmentCache.resolve(
      markdown: stablePrefix,
      style: style
    )
    var segments = cached.segments

    guard !streamingProjection.streamingTail.isEmpty else { return segments }

    let tailBlock = MarkdownBlock.text(streamingProjection.streamingTail)
    if let lastSegment = segments.last,
       case let .prose(prose) = lastSegment
    {
      let mergedProse = MarkdownRenderSegment.Prose(
        identity: prose.identity,
        sourceBlockRange: prose.sourceBlockRange,
        blocks: prose.blocks + [tailBlock]
      )
      segments[segments.count - 1] = .prose(mergedProse)
    } else {
      let startBlockIndex = cached.blockCount
      segments.append(
        .prose(
          MarkdownRenderSegment.Prose(
            identity: .init(kind: .prose, startBlockIndex: startBlockIndex),
            sourceBlockRange: startBlockIndex ..< (startBlockIndex + 1),
            blocks: [tailBlock]
          )
        )
      )
    }

    return segments
  }

  var body: some View {
    let segments = renderSegments

    if !segments.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(segments.enumerated()), id: \.element.identity) { index, segment in
          let previous = index > 0 ? segments[index - 1] : nil
          let spacing = MarkdownRenderSegmentProjector.segmentSpacing(
            previous: previous,
            current: segment,
            style: style
          )

          MarkdownSegmentView(segment: segment, style: style)
            .padding(.top, spacing)
        }

        if shouldCollapse {
          Button {
            isExpanded.toggle()
          } label: {
            Text(collapseButtonTitle)
              .font(.system(size: TypeScale.meta, weight: .medium))
              .foregroundStyle(Color.textTertiary)
              .padding(.top, 6)
          }
          .buttonStyle(.plain)
          .transaction { $0.animation = nil }
        }
      }
      .tint(Color.markdownLink)
      .textSelection(.enabled)
    } else if shouldCollapse {
      Button {
        isExpanded.toggle()
      } label: {
        Text(collapseButtonTitle)
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(Color.textTertiary)
          .padding(.top, 6)
      }
      .buttonStyle(.plain)
      .transaction { $0.animation = nil }
    }
  }
}

private enum MarkdownRenderSegmentCache {
  struct Value: Sendable {
    let blockCount: Int
    let segments: [MarkdownRenderSegment]
  }

  private static let maxEntryCost = 250_000

  private final class Box: NSObject {
    let value: Value

    init(_ value: Value) {
      self.value = value
    }
  }

  private static let cache: NSCache<NSString, Box> = {
    let cache = NSCache<NSString, Box>()
    #if os(iOS)
      cache.countLimit = 64
      cache.totalCostLimit = 6_000_000
    #else
      cache.countLimit = 192
      cache.totalCostLimit = 18_000_000
    #endif
    return cache
  }()

  static func resolve(markdown: String, style: ContentStyle) -> Value {
    let key = "\(style.cacheToken)|\(markdown)" as NSString
    if let cached = cache.object(forKey: key) {
      return cached.value
    }

    let blocks = MarkdownSystemParser.parse(markdown, style: style)
    let value = Value(
      blockCount: blocks.count,
      segments: MarkdownRenderSegmentProjector.project(blocks)
    )
    // Cache cost tracks source markdown size so large transcripts get evicted
    // before parsed segment storage can grow without bound on mobile.
    let estimatedCost = min(max(markdown.utf8.count * 3, 1), maxEntryCost)
    cache.setObject(Box(value), forKey: key, cost: estimatedCost)
    return value
  }
}

private extension ContentStyle {
  var cacheToken: String {
    switch self {
      case .standard:
        "standard"
      case .thinking:
        "thinking"
    }
  }
}
