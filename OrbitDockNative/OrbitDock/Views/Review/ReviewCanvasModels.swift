//
//  ReviewCanvasModels.swift
//  OrbitDock
//
//  Shared review-canvas models that do not need to live in the giant view file.
//

import Foundation

/// Identifies a single navigable element in the unified diff view.
enum ReviewCursorTarget: Equatable, Hashable {
  case fileHeader(fileIndex: Int)
  case hunkHeader(fileIndex: Int, hunkIndex: Int)
  case diffLine(fileIndex: Int, hunkIndex: Int, lineIndex: Int)

  var fileIndex: Int {
    switch self {
      case let .fileHeader(fileIndex): fileIndex
      case let .hunkHeader(fileIndex, _): fileIndex
      case let .diffLine(fileIndex, _, _): fileIndex
    }
  }

  var scrollId: String {
    switch self {
      case let .fileHeader(fileIndex):
        "file-\(fileIndex)"
      case let .hunkHeader(fileIndex, hunkIndex):
        "file-\(fileIndex)-hunk-\(hunkIndex)"
      case let .diffLine(fileIndex, hunkIndex, lineIndex):
        "file-\(fileIndex)-hunk-\(hunkIndex)-line-\(lineIndex)"
    }
  }

  var isFileHeader: Bool {
    if case .fileHeader = self { return true }
    return false
  }

  var isHunkHeader: Bool {
    if case .hunkHeader = self { return true }
    return false
  }
}

struct ReviewComposerLineRange: Equatable {
  let filePath: String
  let fileIndex: Int
  let hunkIndex: Int
  let lineStartIdx: Int
  let lineEndIdx: Int
  let lineStart: UInt32
  let lineEnd: UInt32?
}

/// Records the state when a batch of review comments was sent to the model.
/// Used to detect which files the model modified in response to review feedback.
struct ReviewRound: Equatable {
  let sentAt: Date
  let turnDiffCountAtSend: Int
  let reviewedFilePaths: Set<String>
  let commentCount: Int
}

/// Memoizes `DiffModel.parse()` so review rendering does not re-parse the same diff
/// on every body evaluation.
final class ReviewDiffParseCache {
  private var lastRaw: String?
  private var lastModel: DiffModel?

  func model(for raw: String?) -> DiffModel? {
    if raw == lastRaw { return lastModel }
    lastRaw = raw
    if let raw, !raw.isEmpty {
      lastModel = DiffModel.parse(unifiedDiff: raw)
    } else {
      lastModel = nil
    }
    return lastModel
  }
}
