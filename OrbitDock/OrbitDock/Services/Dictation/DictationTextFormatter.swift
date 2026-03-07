//
//  DictationTextFormatter.swift
//  OrbitDock
//

import CoreMedia
import Foundation

enum DictationTextFormatter {
  nonisolated static func normalizeTranscription(_ text: String) -> String {
    text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { token in
        !token.isEmpty && !isIgnorableToken(token)
      }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated static func merge(existing: String, dictated: String) -> String {
    let normalizedDictated = normalizeTranscription(dictated)
    guard !normalizedDictated.isEmpty else { return existing }

    let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedExisting.isEmpty else { return normalizedDictated }

    return "\(trimmedExisting) \(normalizedDictated)"
  }

  private nonisolated static func isIgnorableToken(_ token: String) -> Bool {
    let upper = token.uppercased()
    if upper == "[BLANK_AUDIO]" || upper == "<|BLANK_AUDIO|>" {
      return true
    }

    guard token.hasPrefix("["), token.hasSuffix("]") else {
      return false
    }

    let core = token.dropFirst().dropLast()
    guard !core.isEmpty else { return false }
    return core.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
  }
}

enum DictationTranscriptAssembler {
  struct Segment: Equatable {
    let range: CMTimeRange
    let text: String
  }

  nonisolated static func updating(
    _ segments: [Segment],
    with segment: Segment
  ) -> [Segment] {
    let normalizedText = DictationTextFormatter.normalizeTranscription(segment.text)
    let candidate = Segment(range: segment.range, text: normalizedText)
    let remainingSegments = segments.filter { existing in
      !rangesOverlap(existing.range, candidate.range)
    }

    let updatedSegments = if candidate.text.isEmpty {
      remainingSegments
    } else {
      remainingSegments + [candidate]
    }

    return updatedSegments.sorted(by: compareSegments)
  }

  nonisolated static func render(_ segments: [Segment]) -> String {
    DictationTextFormatter.normalizeTranscription(
      segments
        .map(\.text)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    )
  }

  private nonisolated static func rangesOverlap(
    _ lhs: CMTimeRange,
    _ rhs: CMTimeRange
  ) -> Bool {
    guard lhs.isValid, rhs.isValid else {
      return false
    }

    return !lhs.intersection(rhs).isEmpty
  }

  private nonisolated static func compareSegments(
    _ lhs: Segment,
    _ rhs: Segment
  ) -> Bool {
    let startComparison = CMTimeCompare(lhs.range.start, rhs.range.start)
    if startComparison == 0 {
      return CMTimeCompare(lhs.range.end, rhs.range.end) < 0
    }
    return startComparison < 0
  }
}
