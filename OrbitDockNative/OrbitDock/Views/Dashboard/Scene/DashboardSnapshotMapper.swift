import Foundation

enum DashboardSnapshotMapper {
  struct EndpointResult: Sendable {
    let revision: UInt64
    let conversations: [DashboardConversationRecord]
    let counts: DashboardTriageCounts
    let directCount: Int
    let endpointId: UUID
    let projectGroups: [DashboardProjectGroup]
  }

  static func mapEndpoint(
    _ payload: ServerDashboardSnapshotPayload,
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus
  ) -> EndpointResult {
    let conversations = payload.conversations.map {
      DashboardConversationRecord(item: $0, endpointId: endpointId, endpointName: endpointName)
    }

    let counts = DashboardTriageCounts(
      attention: Int(payload.counts.attention),
      running: Int(payload.counts.running),
      ready: Int(payload.counts.ready)
    )

    let projectGroups = (payload.projectGroups ?? []).map { group in
      let groupEndpointId = UUID(uuidString: group.endpointId) ?? endpointId
      return DashboardProjectGroup(
        path: group.path,
        name: group.name,
        endpointId: groupEndpointId,
        endpointName: group.endpointName ?? endpointName,
        attentionCount: Int(group.attentionCount),
        workingCount: Int(group.workingCount),
        readyCount: Int(group.readyCount),
        sessionIds: group.sessionIds,
        lastActivityAt: group.lastActivityAt.flatMap { ISO8601DateFormatter().date(from: $0) }
      )
    }

    return EndpointResult(
      revision: payload.revision,
      conversations: conversations,
      counts: counts,
      directCount: Int(payload.counts.direct),
      endpointId: endpointId,
      projectGroups: projectGroups
    )
  }

  static func merge(_ results: [EndpointResult]) -> DashboardSnapshot {
    let revision = results.map(\.revision).max() ?? 0

    let conversations = results.flatMap(\.conversations)
      .sorted { lhs, rhs in
        let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
        let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
        return lhsDate > rhsDate
      }

    let counts = results.reduce(DashboardTriageCounts()) { merged, result in
      merged + result.counts
    }

    let directCount = results.reduce(0) { $0 + $1.directCount }

    let endpointIds = Set(results.map(\.endpointId))

    // Merge project groups from all endpoints, sorted alphabetically
    let projectGroups = results.flatMap(\.projectGroups)
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    return DashboardSnapshot(
      revision: revision,
      conversations: conversations,
      counts: counts,
      directCount: directCount,
      hasMultipleEndpoints: endpointIds.count > 1,
      projectGroups: projectGroups
    )
  }
}
