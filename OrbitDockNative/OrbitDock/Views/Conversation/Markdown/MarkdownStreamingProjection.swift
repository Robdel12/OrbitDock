//
//  MarkdownStreamingProjection.swift
//  OrbitDock
//
//  Conservatively splits streaming markdown into a stable prefix that can use
//  the full renderer and a tail that stays in cheap plain-text mode.
//

import Foundation

struct MarkdownStreamingProjection: Equatable {
  let stablePrefix: String
  let streamingTail: String

  static func make(content: String, isStreaming: Bool) -> MarkdownStreamingProjection {
    guard isStreaming, !content.isEmpty else {
      return MarkdownStreamingProjection(stablePrefix: content, streamingTail: "")
    }

    let boundary = stableBoundary(in: content)
    let splitIndex = content.index(content.startIndex, offsetBy: boundary)

    return MarkdownStreamingProjection(
      stablePrefix: String(content[..<splitIndex]),
      streamingTail: String(content[splitIndex...])
    )
  }

  private static func stableBoundary(in content: String) -> Int {
    let lines = content.components(separatedBy: "\n")
    guard !lines.isEmpty else { return 0 }

    var offset = 0
    var stableBoundary = 0
    var openFenceMarker: String?

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let lineEndOffset = offset + line.count + (index < lines.count - 1 ? 1 : 0)

      if let fenceMarker = fenceMarker(in: trimmed) {
        if openFenceMarker == nil {
          openFenceMarker = fenceMarker
        } else if openFenceMarker == fenceMarker {
          openFenceMarker = nil
          stableBoundary = lineEndOffset
        }

        offset = lineEndOffset
        continue
      }

      if openFenceMarker == nil, trimmed.isEmpty {
        stableBoundary = lineEndOffset
      }

      offset = lineEndOffset
    }

    return stableBoundary
  }

  private static func fenceMarker(in trimmedLine: String) -> String? {
    if trimmedLine.hasPrefix("```") { return "```" }
    if trimmedLine.hasPrefix("~~~") { return "~~~" }
    return nil
  }
}
