import Foundation

enum DashboardSnapshotMapper {
  struct EndpointResult: Sendable {
    let revision: UInt64
    let conversations: [DashboardConversationRecord]
    let counts: DashboardTriageCounts
    let directCount: Int
    let endpointId: UUID
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

    return EndpointResult(
      revision: payload.revision,
      conversations: conversations,
      counts: counts,
      directCount: Int(payload.counts.direct),
      endpointId: endpointId
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

    return DashboardSnapshot(
      revision: revision,
      conversations: conversations,
      counts: counts,
      directCount: directCount,
      hasMultipleEndpoints: endpointIds.count > 1
    )
  }
}
