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
  /// Project groups derived from conversations.
  let projectGroups: [DashboardProjectGroup]

  func replacing(conversations: [DashboardConversationRecord], revision: UInt64? = nil) -> DashboardSnapshot {
    DashboardSnapshot(
      revision: revision ?? self.revision,
      conversations: conversations,
      counts: DashboardTriageCounts(conversations: conversations),
      directCount: conversations.filter(\.isDirect).count,
      hasMultipleEndpoints: hasMultipleEndpoints,
      projectGroups: Self.buildProjectGroups(from: conversations)
    )
  }

  /// Build project groups from conversations.
  /// Mirrors server-side grouping logic: group by (groupingPath, endpointId),
  /// aggregate counts by status, sort alphabetically.
  static func buildProjectGroups(from conversations: [DashboardConversationRecord]) -> [DashboardProjectGroup] {
    struct GroupKey: Hashable {
      let path: String
      let endpointId: UUID
    }

    struct GroupBuilder {
      let path: String
      let name: String
      let endpointId: UUID
      let endpointName: String?
      var attentionCount: Int = 0
      var workingCount: Int = 0
      var readyCount: Int = 0
      var sessionIds: [String] = []
      var lastActivityAt: Date?
    }

    var groups: [GroupKey: GroupBuilder] = [:]

    for conv in conversations {
      let path = conv.serverGroupingPath ?? conv.projectPath
      let name = conv.serverGroupingName
        ?? conv.projectName
        ?? (path as NSString).lastPathComponent

      let key = GroupKey(path: path, endpointId: conv.sessionRef.endpointId)

      var builder = groups[key] ?? GroupBuilder(
        path: path,
        name: name,
        endpointId: conv.sessionRef.endpointId,
        endpointName: conv.endpointName
      )

      builder.sessionIds.append(conv.sessionId)

      switch conv.listStatus {
      case .permission, .question:
        builder.attentionCount += 1
      case .working:
        builder.workingCount += 1
      case .reply:
        builder.readyCount += 1
      case .ended:
        break
      }

      if let activity = conv.lastActivityAt {
        if builder.lastActivityAt == nil || activity > builder.lastActivityAt! {
          builder.lastActivityAt = activity
        }
      }

      groups[key] = builder
    }

    return groups.values
      .map { builder in
        DashboardProjectGroup(
          path: builder.path,
          name: builder.name,
          endpointId: builder.endpointId,
          endpointName: builder.endpointName,
          attentionCount: builder.attentionCount,
          workingCount: builder.workingCount,
          readyCount: builder.readyCount,
          sessionIds: builder.sessionIds,
          lastActivityAt: builder.lastActivityAt
        )
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}
