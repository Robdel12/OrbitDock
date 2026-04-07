import Foundation

struct DashboardSnapshot: Sendable {
  let revision: UInt64
  let conversations: [DashboardConversationRecord]
  let counts: DashboardTriageCounts
  let directCount: Int
  let hasMultipleEndpoints: Bool
}
