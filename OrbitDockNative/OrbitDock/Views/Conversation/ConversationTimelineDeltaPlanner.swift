import Foundation

struct ConversationLatestAppendEvent: Equatable {
  let count: Int
  let nonce: Int
  let requiredVisibleSuffixCount: Int?
}

enum ConversationTimelineDeltaPlanner {
  static func latestAppendedCount(
    oldEntries: [ServerConversationRowEntry],
    newEntries: [ServerConversationRowEntry]
  ) -> Int {
    guard let oldLastSequence = oldEntries.last?.sequence else { return 0 }
    guard !newEntries.isEmpty else { return 0 }

    return newEntries.reduce(into: 0) { count, entry in
      if entry.sequence > oldLastSequence {
        count += 1
      }
    }
  }
}
