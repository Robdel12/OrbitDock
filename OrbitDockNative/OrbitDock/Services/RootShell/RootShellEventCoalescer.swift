import Foundation

enum RootShellEventCoalescer {
  private enum SessionEvent {
    case updated(endpointName: String?, connectionStatus: ConnectionStatus, session: ServerSessionListItem)
    case removed(sessionId: String)
    case ended(sessionId: String, reason: String)
  }

  private struct EndpointBatch {
    var seedRecords: [RootSessionNode]?
    var listSnapshot: (endpointName: String?, connectionStatus: ConnectionStatus, sessions: [ServerSessionListItem])?
    var orderedSessionIDs: [String] = []
    var sessionEvents: [String: SessionEvent] = [:]
    var connectionStatusChange: (endpointName: String?, connectionStatus: ConnectionStatus)?

    mutating func upsertSession(_ sessionId: String, event: SessionEvent) {
      if sessionEvents[sessionId] == nil {
        orderedSessionIDs.append(sessionId)
      }
      sessionEvents[sessionId] = event
    }

    mutating func replaceSnapshot(
      endpointName: String?,
      connectionStatus: ConnectionStatus,
      sessions: [ServerSessionListItem]
    ) {
      listSnapshot = (endpointName, connectionStatus, sessions)
      orderedSessionIDs.removeAll(keepingCapacity: false)
      sessionEvents.removeAll(keepingCapacity: false)
    }
  }

  static func coalesce(_ events: [RootShellEvent]) -> [RootShellEvent] {
    guard events.count > 1 else { return events }

    var orderedEndpointIDs: [UUID] = []
    var endpointBatches: [UUID: EndpointBatch] = [:]
    var latestEndpointFilter: RootShellEndpointFilter?

    func batch(for endpointId: UUID) -> EndpointBatch {
      if endpointBatches[endpointId] == nil {
        endpointBatches[endpointId] = EndpointBatch()
        orderedEndpointIDs.append(endpointId)
      }
      return endpointBatches[endpointId]!
    }

    for event in events {
      switch event {
        case let .seed(endpointId, records):
          var endpointBatch = batch(for: endpointId)
          endpointBatch.seedRecords = records
          endpointBatches[endpointId] = endpointBatch

        case let .sessionsList(endpointId, endpointName, connectionStatus, sessions):
          var endpointBatch = batch(for: endpointId)
          endpointBatch.replaceSnapshot(
            endpointName: endpointName,
            connectionStatus: connectionStatus,
            sessions: sessions
          )
          endpointBatches[endpointId] = endpointBatch

        case let .sessionCreated(endpointId, endpointName, connectionStatus, session),
          let .sessionUpdated(endpointId, endpointName, connectionStatus, session):
          var endpointBatch = batch(for: endpointId)
          endpointBatch.upsertSession(
            session.id,
            event: .updated(
              endpointName: endpointName,
              connectionStatus: connectionStatus,
              session: session
            )
          )
          endpointBatches[endpointId] = endpointBatch

        case let .sessionRemoved(endpointId, sessionId):
          var endpointBatch = batch(for: endpointId)
          endpointBatch.upsertSession(sessionId, event: .removed(sessionId: sessionId))
          endpointBatches[endpointId] = endpointBatch

        case let .sessionEnded(endpointId, sessionId, reason):
          var endpointBatch = batch(for: endpointId)
          endpointBatch.upsertSession(sessionId, event: .ended(sessionId: sessionId, reason: reason))
          endpointBatches[endpointId] = endpointBatch

        case let .endpointConnectionChanged(endpointId, endpointName, connectionStatus):
          var endpointBatch = batch(for: endpointId)
          endpointBatch.connectionStatusChange = (endpointName, connectionStatus)
          endpointBatches[endpointId] = endpointBatch

        case let .endpointFilterChanged(filter):
          latestEndpointFilter = filter
      }
    }

    var coalesced: [RootShellEvent] = []
    coalesced.reserveCapacity(events.count)

    for endpointId in orderedEndpointIDs {
      guard let endpointBatch = endpointBatches[endpointId] else { continue }

      if let seedRecords = endpointBatch.seedRecords {
        coalesced.append(.seed(endpointId: endpointId, records: seedRecords))
      }

      if let listSnapshot = endpointBatch.listSnapshot {
        coalesced.append(.sessionsList(
          endpointId: endpointId,
          endpointName: listSnapshot.endpointName,
          connectionStatus: listSnapshot.connectionStatus,
          sessions: listSnapshot.sessions
        ))
      }

      for sessionId in endpointBatch.orderedSessionIDs {
        guard let sessionEvent = endpointBatch.sessionEvents[sessionId] else { continue }
        switch sessionEvent {
          case let .updated(endpointName, connectionStatus, session):
            coalesced.append(.sessionUpdated(
              endpointId: endpointId,
              endpointName: endpointName,
              connectionStatus: connectionStatus,
              session: session
            ))
          case let .removed(sessionId):
            coalesced.append(.sessionRemoved(endpointId: endpointId, sessionId: sessionId))
          case let .ended(sessionId, reason):
            coalesced.append(.sessionEnded(endpointId: endpointId, sessionId: sessionId, reason: reason))
        }
      }

      if let connectionStatusChange = endpointBatch.connectionStatusChange {
        coalesced.append(.endpointConnectionChanged(
          endpointId: endpointId,
          endpointName: connectionStatusChange.endpointName,
          connectionStatus: connectionStatusChange.connectionStatus
        ))
      }
    }

    if let latestEndpointFilter {
      coalesced.append(.endpointFilterChanged(latestEndpointFilter))
    }

    return coalesced
  }
}
