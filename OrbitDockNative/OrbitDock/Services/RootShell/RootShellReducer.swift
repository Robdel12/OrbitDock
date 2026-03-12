import Foundation

struct RootShellState: Equatable, Sendable {
  var recordsByScopedID: [String: RootSessionNode] = [:]
  var orderedScopedIDs: [String] = []
  var endpointHealthByID: [UUID: RootShellEndpointHealth] = [:]
  var counts = RootShellCounts()
  var selectedEndpointFilter: RootShellEndpointFilter = .all

  nonisolated init(
    recordsByScopedID: [String: RootSessionNode] = [:],
    orderedScopedIDs: [String] = [],
    endpointHealthByID: [UUID: RootShellEndpointHealth] = [:],
    counts: RootShellCounts = RootShellCounts(),
    selectedEndpointFilter: RootShellEndpointFilter = .all
  ) {
    self.recordsByScopedID = recordsByScopedID
    self.orderedScopedIDs = orderedScopedIDs
    self.endpointHealthByID = endpointHealthByID
    self.counts = counts
    self.selectedEndpointFilter = selectedEndpointFilter
  }
}

enum RootShellReducer {
  @discardableResult
  nonisolated static func reduce(state: inout RootShellState, event: RootShellEvent) -> Bool {
    var changed = false

    switch event {
      case let .seed(endpointId, records):
        let existing = state.recordsByScopedID.filter { key, _ in
          return !key.hasPrefix(recordScopedPrefix(for: endpointId))
        }
        var nextRecords = existing
        for record in records {
          nextRecords[record.scopedID] = record
        }
        if nextRecords != state.recordsByScopedID {
          state.recordsByScopedID = nextRecords
          refreshDerivedState(&state)
          changed = true
        }

      case let .sessionsList(endpointId, endpointName, connectionStatus, sessions):
        changed = applySessionsList(
          into: &state,
          endpointId: endpointId,
          endpointName: endpointName,
          connectionStatus: connectionStatus,
          sessions: sessions
        )

      case let .sessionCreated(endpointId, endpointName, connectionStatus, session),
        let .sessionUpdated(endpointId, endpointName, connectionStatus, session):
        let record = RootSessionNode(
          session: session,
          endpointId: endpointId,
          endpointName: endpointName,
          connectionStatus: connectionStatus
        )
        if state.recordsByScopedID[record.scopedID] != record {
          state.recordsByScopedID[record.scopedID] = record
          refreshDerivedState(&state)
          changed = true
        }

      case let .sessionEnded(endpointId, sessionId, reason):
        let scopedID = ScopedSessionID(endpointId: endpointId, sessionId: sessionId).scopedID
        if let record = state.recordsByScopedID[scopedID] {
          let endedRecord = record.ended(reason: reason)
          if endedRecord != record {
            state.recordsByScopedID[scopedID] = endedRecord
            refreshDerivedState(&state)
            changed = true
          }
        }

      case let .endpointConnectionChanged(endpointId, endpointName, connectionStatus):
        for (scopedID, record) in state.recordsByScopedID where record.sessionRef.endpointId == endpointId {
          let nextRecord = record.withConnectionStatus(
            connectionStatus,
            endpointName: endpointName
          )
          if nextRecord != record {
            state.recordsByScopedID[scopedID] = nextRecord
            changed = true
          }
        }
        if changed {
          refreshDerivedState(&state)
        }

      case let .endpointFilterChanged(filter):
        if endpointFiltersDiffer(state.selectedEndpointFilter, filter) {
          state.selectedEndpointFilter = filter
          changed = true
        }
    }

    return changed
  }

  nonisolated private static func applySessionsList(
    into state: inout RootShellState,
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus,
    sessions: [ServerSessionListItem]
  ) -> Bool {
    let scopedIDs = Set(sessions.map { ScopedSessionID(endpointId: endpointId, sessionId: $0.id).scopedID })
    let retainedRecords = state.recordsByScopedID.filter { key, _ in
      guard key.hasPrefix(recordScopedPrefix(for: endpointId)) else { return true }
      return scopedIDs.contains(key)
    }
    var nextRecords = retainedRecords

    for session in sessions {
      let record = RootSessionNode(
        session: session,
        endpointId: endpointId,
        endpointName: endpointName,
        connectionStatus: connectionStatus
      )
      nextRecords[record.scopedID] = record
    }

    guard nextRecords != state.recordsByScopedID else {
      return false
    }

    state.recordsByScopedID = nextRecords
    refreshDerivedState(&state)
    return true
  }

  nonisolated private static func refreshDerivedState(_ state: inout RootShellState) {
    let records = state.recordsByScopedID.values

    state.orderedScopedIDs = records
      .sorted(by: compareRecords)
      .map(\.scopedID)

    state.counts = records.reduce(into: RootShellCounts()) { counts, record in
      counts.total += 1
      guard record.isActive else { return }
      counts.active += 1
      if record.listStatus == .working {
        counts.working += 1
      }
      if record.needsAttention {
        counts.attention += 1
      }
      if record.isReady {
        counts.ready += 1
      }
    }

    let grouped = Dictionary(grouping: records, by: { $0.sessionRef.endpointId })
    state.endpointHealthByID = grouped.reduce(into: [:]) { result, entry in
      let endpointId = entry.key
      let endpointRecords = entry.value
      let counts = endpointRecords.reduce(into: RootShellCounts()) { counts, record in
        counts.total += 1
        guard record.isActive else { return }
        counts.active += 1
        if record.listStatus == .working {
          counts.working += 1
        }
        if record.needsAttention {
          counts.attention += 1
        }
        if record.isReady {
          counts.ready += 1
        }
      }

      let sample = endpointRecords.first
      result[endpointId] = RootShellEndpointHealth(
        endpointId: endpointId,
        endpointName: sample?.endpointName ?? "Server",
        connectionStatus: sample?.endpointConnectionStatus ?? .disconnected,
        counts: counts
      )
    }
  }

  nonisolated private static func compareRecords(_ lhs: RootSessionNode, _ rhs: RootSessionNode) -> Bool {
    if lhs.isActive != rhs.isActive {
      return lhs.isActive && !rhs.isActive
    }

    let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
    let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
    if lhsDate != rhsDate {
      return lhsDate > rhsDate
    }

    if lhs.titleSortKey != rhs.titleSortKey {
      return lhs.titleSortKey < rhs.titleSortKey
    }

    if lhs.endpointName != rhs.endpointName {
      return (lhs.endpointName ?? "") < (rhs.endpointName ?? "")
    }

    if lhs.sessionRef.endpointId != rhs.sessionRef.endpointId {
      return lhs.sessionRef.endpointId.uuidString < rhs.sessionRef.endpointId.uuidString
    }
    return lhs.sessionRef.sessionId < rhs.sessionRef.sessionId
  }

  nonisolated private static func recordScopedPrefix(for endpointId: UUID) -> String {
    "\(endpointId.uuidString)\(SessionRef.delimiter)"
  }

  nonisolated private static func endpointFiltersDiffer(
    _ lhs: RootShellEndpointFilter,
    _ rhs: RootShellEndpointFilter
  ) -> Bool {
    switch (lhs, rhs) {
      case (.all, .all):
        false
      case let (.endpoint(lhsID), .endpoint(rhsID)):
        lhsID != rhsID
      default:
        true
    }
  }
}
