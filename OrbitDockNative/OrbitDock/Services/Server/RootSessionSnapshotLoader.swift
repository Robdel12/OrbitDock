import Foundation

@MainActor
enum RootSessionSnapshotLoader {
  static func fetchLibrarySessions(
    from runtimeRegistry: ServerRuntimeRegistry,
    pageSize: Int = 200
  ) async -> [RootSessionNode] {
    var sessionsByScopedID: [String: RootSessionNode] = [:]

    for runtime in runtimeRegistry.runtimes where runtime.endpoint.isEnabled {
      let endpointId = runtime.endpoint.id
      let endpointName = runtime.endpoint.name
      let connectionStatus = runtime.connection.connectionStatus
      var offset = 0

      while true {
        do {
          let page = try await runtime.clients.archivedSessions.fetchSnapshot(
            limit: pageSize,
            offset: offset
          )
          for item in page.sessions {
            let session = RootSessionNode(
              session: item,
              endpointId: endpointId,
              endpointName: endpointName,
              connectionStatus: connectionStatus
            )
            sessionsByScopedID[session.scopedID] = session
          }

          guard let nextOffset = page.nextOffset.map(Int.init), nextOffset > offset else {
            break
          }
          offset = nextOffset
        } catch {
          break
        }
      }
    }

    return sortSessions(Array(sessionsByScopedID.values))
  }

  static func sortSessions(_ sessions: [RootSessionNode]) -> [RootSessionNode] {
    sessions.sorted { lhs, rhs in
      if lhs.isActive != rhs.isActive { return lhs.isActive }
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      return lhsDate > rhsDate
    }
  }

  static func counts(from sessions: [RootSessionNode]) -> RootShellCounts {
    sessions.reduce(into: RootShellCounts()) { counts, record in
      counts.total += 1
      guard record.isActive else { return }
      counts.active += 1
      if record.listStatus == .working { counts.working += 1 }
      if record.needsAttention { counts.attention += 1 }
      if record.isReady { counts.ready += 1 }
    }
  }

  static func missionControlSessions(from sessions: [RootSessionNode], limit: Int? = nil) -> [RootSessionNode] {
    let filtered = sessions.filter(\.showsInMissionControl)
    if let limit {
      return Array(filtered.prefix(limit))
    }
    return filtered
  }

  static func recentSessions(from sessions: [RootSessionNode], limit: Int? = nil) -> [RootSessionNode] {
    let filtered = sessions
      .filter { !$0.showsInMissionControl }
      .sorted {
        let lhsDate = $0.lastActivityAt ?? $0.endedAt ?? $0.startedAt ?? .distantPast
        let rhsDate = $1.lastActivityAt ?? $1.endedAt ?? $1.startedAt ?? .distantPast
        return lhsDate > rhsDate
      }
    if let limit {
      return Array(filtered.prefix(limit))
    }
    return filtered
  }
}
