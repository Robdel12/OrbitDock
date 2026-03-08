//
//  ComposerImageAttachmentPolicy.swift
//  OrbitDock
//

import Foundation

nonisolated enum ComposerImageAttachmentPolicy {
  static let maxImageCount = 5
  // Attachments upload individually, so the main limit is per-image reliability,
  // not one giant serialized turn payload.
  static let maxSingleImageBytes = 12 * 1024 * 1024
  static let maxTotalRawBytes = maxImageCount * maxSingleImageBytes
  static let nearLimitFraction = 0.85

  nonisolated enum Validation: Equatable, Sendable {
    case allowed
    case tooMany(maxCount: Int)
    case tooLarge(maxBytes: Int)
  }

  static func usedRawBytes(_ values: [Int]) -> Int {
    values.reduce(0) { partial, value in
      partial + max(0, value)
    }
  }

  static func budgetFraction(usedRawBytes: Int) -> Double {
    guard maxTotalRawBytes > 0 else { return 1 }
    return min(1, Double(max(0, usedRawBytes)) / Double(maxTotalRawBytes))
  }

  static func estimatedTransportBytes(forRawBytes rawBytes: Int) -> Int {
    let safeBytes = max(0, rawBytes)
    return ((safeBytes + 2) / 3) * 4
  }

  static func remainingBytes(usedRawBytes: Int) -> Int {
    max(0, maxTotalRawBytes - max(0, usedRawBytes))
  }

  static func validateAddition(
    existingCount: Int,
    usedRawBytes: Int,
    candidateRawBytes: Int
  ) -> Validation {
    if existingCount >= maxImageCount {
      return .tooMany(maxCount: maxImageCount)
    }

    let normalizedCandidateBytes = max(0, candidateRawBytes)
    guard normalizedCandidateBytes <= maxSingleImageBytes else {
      return .tooLarge(maxBytes: maxSingleImageBytes)
    }

    let projectedTotal = usedRawBytes + normalizedCandidateBytes
    guard projectedTotal <= maxTotalRawBytes else {
      return .tooLarge(maxBytes: maxTotalRawBytes)
    }

    return .allowed
  }

  static func message(for validation: Validation) -> String? {
    switch validation {
      case .allowed:
        return nil
      case let .tooMany(maxCount):
        return "You can attach up to \(maxCount) images in one turn."
      case let .tooLarge(maxBytes):
        return
          "That image is still too large to upload reliably. "
          + "Try a smaller screenshot or keep it under \(formatBytes(maxBytes))."
    }
  }

  static func isPolicyMessage(_ message: String) -> Bool {
    message.contains("upload reliably")
      || message.contains("attach up to")
  }

  static func formatBytes(_ bytes: Int) -> String {
    let safeBytes = max(0, bytes)
    if safeBytes < 1_024 {
      return "\(safeBytes) B"
    }
    if safeBytes < 1_024 * 1_024 {
      return String(format: "%.1f KB", Double(safeBytes) / 1_024)
    }
    return String(format: "%.1f MB", Double(safeBytes) / (1_024 * 1_024))
  }
}
