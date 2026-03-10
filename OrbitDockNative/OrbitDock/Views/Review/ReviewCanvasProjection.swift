//
//  ReviewCanvasProjection.swift
//  OrbitDock
//
//  Pure review projection helpers for banner, file status, and comment-derived UI state.
//

import Foundation

enum ReviewBannerTone: Equatable {
  case pending
  case progress
}

struct ReviewBannerState: Equatable {
  let tone: ReviewBannerTone
  let iconName: String
  let title: String
  let detail: String?
}

struct ReviewSendBarState: Equatable {
  let openCommentCount: Int
  let selectedCommentCount: Int

  var hasSelection: Bool {
    selectedCommentCount > 0
  }

  var sendCount: Int {
    hasSelection ? selectedCommentCount : openCommentCount
  }

  var label: String {
    if hasSelection {
      return "Send \(sendCount) selected"
    }
    return "Send \(sendCount) comment\(sendCount == 1 ? "" : "s") to model"
  }
}

enum ReviewCanvasProjection {
  static func commentMatchesTurnView(
    _ comment: ServerReviewComment,
    activeTurnId: String?
  ) -> Bool {
    guard let activeTurnId else { return true }
    return comment.turnId == nil || comment.turnId == activeTurnId
  }

  static func openComments(
    from comments: [ServerReviewComment],
    activeTurnId: String?
  ) -> [ServerReviewComment] {
    comments.filter { $0.status == .open && commentMatchesTurnView($0, activeTurnId: activeTurnId) }
  }

  static func hasResolvedComments(
    comments: [ServerReviewComment],
    activeTurnId: String?
  ) -> Bool {
    comments.contains { $0.status == .resolved && commentMatchesTurnView($0, activeTurnId: activeTurnId) }
  }

  static func commentCounts(
    comments: [ServerReviewComment],
    activeTurnId: String?
  ) -> [String: Int] {
    var counts: [String: Int] = [:]
    for comment in openComments(from: comments, activeTurnId: activeTurnId) {
      counts[comment.filePath, default: 0] += 1
    }
    return counts
  }

  static func commentedNewLineNums(
    comments: [ServerReviewComment],
    filePath: String,
    activeTurnId: String?,
    showResolvedComments: Bool
  ) -> Set<Int> {
    var result = Set<Int>()
    for comment in comments
      where comment.filePath == filePath && commentMatchesTurnView(comment, activeTurnId: activeTurnId)
    {
      if !showResolvedComments, comment.status != .open { continue }
      let start = Int(comment.lineStart)
      let end = Int(comment.lineEnd ?? comment.lineStart)
      for line in start ... end {
        result.insert(line)
      }
    }
    return result
  }

  static func commentsForLine(
    comments: [ServerReviewComment],
    filePath: String,
    lineNum: Int,
    activeTurnId: String?
  ) -> [ServerReviewComment] {
    comments.filter {
      $0.filePath == filePath &&
        Int($0.lineEnd ?? $0.lineStart) == lineNum &&
        commentMatchesTurnView($0, activeTurnId: activeTurnId)
    }
  }

  static func groupedResolvedComments(
    comments: [ServerReviewComment],
    filePath: String,
    activeTurnId: String?
  ) -> [Int: [ServerReviewComment]] {
    let resolved = comments.filter {
      $0.filePath == filePath &&
        $0.status == .resolved &&
        commentMatchesTurnView($0, activeTurnId: activeTurnId)
    }

    guard !resolved.isEmpty else { return [:] }

    var byLineEnd: [Int: [ServerReviewComment]] = [:]
    for comment in resolved {
      let lineEnd = Int(comment.lineEnd ?? comment.lineStart)
      byLineEnd[lineEnd, default: []].append(comment)
    }

    let sortedLines = byLineEnd.keys.sorted()
    var merged: [Int: [ServerReviewComment]] = [:]
    var currentGroup: [ServerReviewComment] = []
    var currentEnd: Int = -10

    for lineNum in sortedLines {
      if lineNum <= currentEnd + 1 {
        currentGroup.append(contentsOf: byLineEnd[lineNum] ?? [])
        currentEnd = lineNum
      } else {
        if !currentGroup.isEmpty {
          merged[currentEnd] = currentGroup
        }
        currentGroup = byLineEnd[lineNum] ?? []
        currentEnd = lineNum
      }
    }

    if !currentGroup.isEmpty {
      merged[currentEnd] = currentGroup
    }

    return merged
  }

  static func unresolvedCommentLineMap(
    comments: [ServerReviewComment],
    activeTurnId: String?
  ) -> [String: Set<Int>] {
    var map: [String: Set<Int>] = [:]
    for comment in openComments(from: comments, activeTurnId: activeTurnId) {
      map[comment.filePath, default: []].insert(Int(comment.lineStart))
    }
    return map
  }

  static func sendBarState(
    comments: [ServerReviewComment],
    selectedCommentIds: Set<String>,
    activeTurnId: String?
  ) -> ReviewSendBarState? {
    let openComments = openComments(from: comments, activeTurnId: activeTurnId)
    guard !openComments.isEmpty else { return nil }
    let selectedCount = openComments.filter { selectedCommentIds.contains($0.id) }.count
    return ReviewSendBarState(
      openCommentCount: openComments.count,
      selectedCommentCount: selectedCount
    )
  }

  static func addressedFileStatus(
    filePath: String,
    lastReviewRound: ReviewRound?,
    turnDiffs: [ServerTurnDiff]
  ) -> Bool? {
    guard let lastReviewRound else { return nil }
    guard lastReviewRound.reviewedFilePaths.contains(filePath) else { return nil }

    let addressed = ReviewWorkflow.addressedFilePaths(
      reviewedFilePaths: lastReviewRound.reviewedFilePaths,
      turnDiffCountAtSend: lastReviewRound.turnDiffCountAtSend,
      turnDiffs: turnDiffs
    )
    return addressed.contains(filePath)
  }

  static func bannerState(
    lastReviewRound: ReviewRound?,
    showReviewBanner: Bool,
    turnDiffs: [ServerTurnDiff]
  ) -> ReviewBannerState? {
    guard showReviewBanner, let lastReviewRound else { return nil }

    let addressed = ReviewWorkflow.addressedFilePaths(
      reviewedFilePaths: lastReviewRound.reviewedFilePaths,
      turnDiffCountAtSend: lastReviewRound.turnDiffCountAtSend,
      turnDiffs: turnDiffs
    )
    let hasChanges = ReviewWorkflow.hasPostReviewChanges(
      turnDiffCountAtSend: lastReviewRound.turnDiffCountAtSend,
      turnDiffs: turnDiffs
    )

    if hasChanges {
      let total = lastReviewRound.reviewedFilePaths.count
      return ReviewBannerState(
        tone: .progress,
        iconName: addressed.count == total ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
        title: "\(addressed.count) of \(total) reviewed file\(total == 1 ? "" : "s") updated",
        detail: nil
      )
    }

    let fileCount = lastReviewRound.reviewedFilePaths.count
    return ReviewBannerState(
      tone: .pending,
      iconName: "paperplane.fill",
      title: "Review sent",
      detail: "\(lastReviewRound.commentCount) comment\(lastReviewRound.commentCount == 1 ? "" : "s") on \(fileCount) file\(fileCount == 1 ? "" : "s")"
    )
  }
}
