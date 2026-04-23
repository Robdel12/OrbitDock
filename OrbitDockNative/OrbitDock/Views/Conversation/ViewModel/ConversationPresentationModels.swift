import Foundation

enum ConversationHistoryPaging {
  struct MergeResult {
    let rows: [ServerConversationRowEntry]
    let hasMoreBefore: Bool
    let totalRowCount: UInt64
  }

  static func mergeBootstrap(
    existingRows: [ServerConversationRowEntry],
    existingHasMoreBefore: Bool,
    existingTotalRowCount: UInt64,
    bootstrapRows: [ServerConversationRowEntry],
    bootstrapHasMoreBefore: Bool,
    bootstrapTotalRowCount: UInt64
  ) -> MergeResult {
    let normalizedBootstrapRows = normalizedRows(bootstrapRows)
    guard
      let bootstrapOldestSequence = normalizedBootstrapRows.first?.sequence,
      let bootstrapNewestSequence = normalizedBootstrapRows.last?.sequence
    else {
      return MergeResult(
        rows: normalizedBootstrapRows,
        hasMoreBefore: bootstrapHasMoreBefore,
        totalRowCount: bootstrapTotalRowCount
      )
    }

    let preservedBoundaryRows = existingRows.filter {
      $0.sequence < bootstrapOldestSequence || $0.sequence > bootstrapNewestSequence
    }
    let preservesNewerTail = existingRows.contains { $0.sequence > bootstrapNewestSequence }
    let bootstrapLooksLikeWindowedRefresh =
      existingTotalRowCount >= UInt64(existingRows.count)
        && bootstrapTotalRowCount >= UInt64(existingRows.count)
    let shouldPreserveBoundaryRows = preservesNewerTail || bootstrapLooksLikeWindowedRefresh

    guard shouldPreserveBoundaryRows, !preservedBoundaryRows.isEmpty else {
      return MergeResult(
        rows: normalizedBootstrapRows,
        hasMoreBefore: bootstrapHasMoreBefore,
        totalRowCount: bootstrapTotalRowCount
      )
    }

    let mergedRows = normalizedRows(preservedBoundaryRows + normalizedBootstrapRows)
    return MergeResult(
      rows: mergedRows,
      hasMoreBefore: existingHasMoreBefore,
      totalRowCount: max(bootstrapTotalRowCount, UInt64(mergedRows.count))
    )
  }

  static func mergeOlderPage(
    existingRows: [ServerConversationRowEntry],
    page: ServerConversationHistoryPage
  ) -> MergeResult {
    MergeResult(
      rows: normalizedRows(page.rows + existingRows),
      hasMoreBefore: page.hasMoreBefore,
      totalRowCount: page.totalRowCount
    )
  }

  static func mergeOlderPage(
    existingRows: [ServerConversationRowEntry],
    page: ServerAgentThreadConversationPage
  ) -> MergeResult {
    MergeResult(
      rows: normalizedRows(page.rows + existingRows),
      hasMoreBefore: page.hasMoreBefore,
      totalRowCount: page.totalRowCount
    )
  }

  private static func normalizedRows(
    _ rows: [ServerConversationRowEntry]
  ) -> [ServerConversationRowEntry] {
    var entriesByID: [String: ServerConversationRowEntry] = [:]
    for row in rows {
      entriesByID[row.id] = row
    }
    return entriesByID.values.sorted { lhs, rhs in
      if lhs.sequence == rhs.sequence {
        return lhs.id < rhs.id
      }
      return lhs.sequence < rhs.sequence
    }
  }
}

struct ConversationSnapshot {
  let timeline: ConversationTimelinePresentation?
  let conversationLoaded: Bool
  let forkOrigin: ConversationForkOriginPresentation?

  static let empty = ConversationSnapshot(
    timeline: nil,
    conversationLoaded: false,
    forkOrigin: nil
  )
}

struct ConversationForkOriginPresentation {
  let sourceSessionId: String
  let sourceEndpointId: UUID?
  let sourceName: String?
}

struct ConversationTimelinePresentation {
  let entries: [ServerConversationRowEntry]
  let contentRevision: Int
  let structureRevision: Int
  let changedEntries: [ServerConversationRowEntry]
}
