import Foundation
import SwiftUI

/// Pre-computed project group from server.
/// Server computes grouping once; clients render directly without re-grouping.
struct DashboardProjectGroup: Identifiable, Sendable {
  let path: String
  let name: String
  let endpointId: UUID
  let endpointName: String?
  let attentionCount: Int
  let workingCount: Int
  let readyCount: Int
  let sessionIds: [String]
  let lastActivityAt: Date?

  var id: String { "\(path)::\(endpointId.uuidString)" }

  var totalCount: Int { attentionCount + workingCount + readyCount }

  var signalColor: Color {
    if attentionCount > 0 { return .statusPermission }
    if workingCount > 0 { return .statusWorking }
    return .statusReply
  }
}

struct DashboardSnapshot: Sendable {
  let revision: UInt64
  let conversations: [DashboardConversationRecord]
  let counts: DashboardTriageCounts
  let directCount: Int
  let hasMultipleEndpoints: Bool
  /// Pre-computed project groups from server, sorted alphabetically.
  let projectGroups: [DashboardProjectGroup]

  func replacing(conversations: [DashboardConversationRecord], revision: UInt64? = nil) -> DashboardSnapshot {
    DashboardSnapshot(
      revision: revision ?? self.revision,
      conversations: conversations,
      counts: DashboardTriageCounts(conversations: conversations),
      directCount: conversations.filter(\.isDirect).count,
      hasMultipleEndpoints: hasMultipleEndpoints,
      projectGroups: projectGroups
    )
  }
}
