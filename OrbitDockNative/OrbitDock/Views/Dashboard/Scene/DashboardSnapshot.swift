import Foundation

struct DashboardSnapshot: Sendable {
  let revision: UInt64
  let conversations: [DashboardConversationRecord]
  let counts: DashboardTriageCounts
  let directCount: Int
  let hasMultipleEndpoints: Bool

  func replacing(conversations: [DashboardConversationRecord], revision: UInt64? = nil) -> DashboardSnapshot {
    DashboardSnapshot(
      revision: revision ?? self.revision,
      conversations: conversations,
      counts: DashboardTriageCounts(conversations: conversations),
      directCount: conversations.filter(\.isDirect).count,
      hasMultipleEndpoints: hasMultipleEndpoints
    )
  }
}
