//
//  MarkdownRenderSegmentProjector.swift
//  OrbitDock
//
//  Pure transform from semantic markdown blocks into stable render segments.
//

import Foundation

enum MarkdownRenderSegmentProjector {
  static func project(_ blocks: [MarkdownBlock]) -> [MarkdownRenderSegment] {
    guard !blocks.isEmpty else { return [] }

    var segments: [MarkdownRenderSegment] = []
    var proseStartIndex: Int?
    var proseBlocks: [MarkdownBlock] = []

    func flushProse(upTo endIndex: Int) {
      guard let startBlockIndex = proseStartIndex, !proseBlocks.isEmpty else { return }
      let identity = MarkdownRenderSegment.Identity(kind: .prose, startBlockIndex: startBlockIndex)
      let segment = MarkdownRenderSegment.prose(
        MarkdownRenderSegment.Prose(
          identity: identity,
          sourceBlockRange: startBlockIndex..<endIndex,
          blocks: proseBlocks
        )
      )
      segments.append(segment)
      proseStartIndex = nil
      proseBlocks.removeAll(keepingCapacity: true)
    }

    for (index, block) in blocks.enumerated() {
      if isProseRenderable(block) {
        if proseStartIndex == nil {
          proseStartIndex = index
        }
        proseBlocks.append(block)
        continue
      }

      flushProse(upTo: index)
      segments.append(segment(for: block, at: index))
    }

    flushProse(upTo: blocks.count)
    return segments
  }

  static func segmentSpacing(
    previous: MarkdownRenderSegment?,
    current: MarkdownRenderSegment,
    style: ContentStyle
  ) -> CGFloat {
    guard let previous,
          let previousBlock = previous.trailingBlock,
          let currentBlock = current.leadingBlock
    else { return 0 }

    return MarkdownTypography.interBlockSpacing(
      previous: previousBlock,
      current: currentBlock,
      style: style
    )
  }

  private static func segment(for block: MarkdownBlock, at index: Int) -> MarkdownRenderSegment {
    let identity = MarkdownRenderSegment.Identity(kind: kind(for: block), startBlockIndex: index)
    let sourceBlockRange = index..<(index + 1)

    switch block {
      case let .codeBlock(language, code):
        return .codeBlock(
          MarkdownRenderSegment.CodeBlock(
            identity: identity,
            sourceBlockRange: sourceBlockRange,
            language: language,
            code: code
          )
        )

      case let .table(headers, rows):
        return .table(
          MarkdownRenderSegment.Table(
            identity: identity,
            sourceBlockRange: sourceBlockRange,
            headers: headers,
            rows: rows
          )
        )

      case .thematicBreak:
        return .thematicBreak(
          MarkdownRenderSegment.ThematicBreak(
            identity: identity,
            sourceBlockRange: sourceBlockRange
          )
        )

      case .text, .heading, .blockquote, .list:
        preconditionFailure("Prose-capable blocks must be handled by the prose path.")
    }
  }

  private static func kind(for block: MarkdownBlock) -> MarkdownRenderSegment.Kind {
    switch block {
      case .text, .heading, .blockquote, .list:
        return .prose
      case .codeBlock:
        return .codeBlock
      case .table:
        return .table
      case .thematicBreak:
        return .thematicBreak
    }
  }

  private static func isProseRenderable(_ block: MarkdownBlock) -> Bool {
    switch block {
      case .text, .heading, .blockquote, .list:
        return true
      case .codeBlock, .table, .thematicBreak:
        return false
    }
  }
}
