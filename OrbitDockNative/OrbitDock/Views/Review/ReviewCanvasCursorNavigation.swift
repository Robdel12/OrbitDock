//
//  ReviewCanvasCursorNavigation.swift
//  OrbitDock
//
//  Pure cursor and collapse helpers for the review canvas.
//

import Foundation

enum ReviewCursorNavigation {
  static func visibleTargets(
    in model: DiffModel,
    collapsedFiles: Set<String>,
    collapsedHunks: Set<String>
  ) -> [ReviewCursorTarget] {
    var targets: [ReviewCursorTarget] = []
    for (fileIndex, file) in model.files.enumerated() {
      targets.append(.fileHeader(fileIndex: fileIndex))
      guard !collapsedFiles.contains(file.id) else { continue }
      for (hunkIndex, hunk) in file.hunks.enumerated() {
        targets.append(.hunkHeader(fileIndex: fileIndex, hunkIndex: hunkIndex))
        let hunkKey = hunkCollapseKey(fileIndex: fileIndex, hunkIndex: hunkIndex)
        guard !collapsedHunks.contains(hunkKey) else { continue }
        for lineIndex in 0 ..< hunk.lines.count {
          targets.append(.diffLine(fileIndex: fileIndex, hunkIndex: hunkIndex, lineIndex: lineIndex))
        }
      }
    }
    return targets
  }

  static func currentTarget(cursorIndex: Int, targets: [ReviewCursorTarget]) -> ReviewCursorTarget? {
    guard !targets.isEmpty else { return nil }
    return targets[min(cursorIndex, targets.count - 1)]
  }

  static func currentFileIndex(target: ReviewCursorTarget?) -> Int {
    target?.fileIndex ?? 0
  }

  static func currentFile(in model: DiffModel, target: ReviewCursorTarget?) -> FileDiff? {
    let index = currentFileIndex(target: target)
    guard index < model.files.count else { return nil }
    return model.files[index]
  }

  static func isCursorOnHunkHeader(
    fileIndex: Int,
    hunkIndex: Int,
    target: ReviewCursorTarget?
  ) -> Bool {
    target == .hunkHeader(fileIndex: fileIndex, hunkIndex: hunkIndex)
  }

  static func cursorLineForHunk(
    fileIndex: Int,
    hunkIndex: Int,
    target: ReviewCursorTarget?
  ) -> Int? {
    guard case let .diffLine(targetFileIndex, targetHunkIndex, lineIndex) = target,
          targetFileIndex == fileIndex,
          targetHunkIndex == hunkIndex
    else { return nil }
    return lineIndex
  }

  static func clampedCursorIndex(cursorIndex: Int, targets: [ReviewCursorTarget]) -> Int {
    guard !targets.isEmpty else { return 0 }
    return min(cursorIndex, targets.count - 1)
  }

  static func autoFollowFileHeaderIndex(
    isFollowing: Bool,
    isSessionActive: Bool,
    previousFileCount: Int,
    newFileCount: Int,
    targets: [ReviewCursorTarget]
  ) -> Int? {
    guard isFollowing, isSessionActive, newFileCount > previousFileCount else { return nil }
    return targets.lastIndex(where: \.isFileHeader)
  }

  static func movedCursor(
    currentIndex: Int,
    delta: Int,
    targets: [ReviewCursorTarget]
  ) -> Int? {
    guard !targets.isEmpty else { return nil }
    return max(0, min(currentIndex + delta, targets.count - 1))
  }

  static func jumpedToNextSection(
    currentIndex: Int,
    forward: Bool,
    targets: [ReviewCursorTarget]
  ) -> Int? {
    guard !targets.isEmpty else { return nil }
    let safeIndex = min(currentIndex, targets.count - 1)

    if forward {
      for index in (safeIndex + 1) ..< targets.count {
        if targets[index].isHunkHeader || targets[index].isFileHeader {
          return index
        }
      }
      return nil
    }

    let onHeader = targets[safeIndex].isHunkHeader || targets[safeIndex].isFileHeader
    let startIndex = onHeader ? safeIndex - 1 : safeIndex
    guard startIndex >= 0 else { return nil }

    for index in stride(from: startIndex, through: 0, by: -1) {
      if targets[index].isHunkHeader || targets[index].isFileHeader {
        return index
      }
    }
    return nil
  }

  static func toggledFileCollapse(fileId: String, collapsedFiles: Set<String>) -> Set<String> {
    var collapsedFiles = collapsedFiles
    if collapsedFiles.contains(fileId) {
      collapsedFiles.remove(fileId)
    } else {
      collapsedFiles.insert(fileId)
    }
    return collapsedFiles
  }

  static func toggledHunkCollapse(hunkKey: String, collapsedHunks: Set<String>) -> Set<String> {
    var collapsedHunks = collapsedHunks
    if collapsedHunks.contains(hunkKey) {
      collapsedHunks.remove(hunkKey)
    } else {
      collapsedHunks.insert(hunkKey)
    }
    return collapsedHunks
  }

  static func fileHeaderIndex(fileIndex: Int, targets: [ReviewCursorTarget]) -> Int? {
    targets.firstIndex(of: .fileHeader(fileIndex: fileIndex))
  }

  static func hunkHeaderIndex(fileIndex: Int, hunkIndex: Int, targets: [ReviewCursorTarget]) -> Int? {
    targets.firstIndex(of: .hunkHeader(fileIndex: fileIndex, hunkIndex: hunkIndex))
  }

  static func hunkCollapseKey(fileIndex: Int, hunkIndex: Int) -> String {
    "\(fileIndex)-\(hunkIndex)"
  }
}
