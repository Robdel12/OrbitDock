import Foundation

enum UnifiedEndpointFilter: Hashable, Sendable {
  case all
  case endpoint(UUID)
}

struct UnifiedSessionCounts: Equatable, Sendable {
  var total = 0
  var active = 0
  var working = 0
  var attention = 0
  var ready = 0
}

struct UnifiedEndpointHealth: Identifiable, Sendable {
  let endpointId: UUID
  let endpointName: String
  let status: ConnectionStatus
  let counts: UnifiedSessionCounts

  var id: UUID {
    endpointId
  }
}

struct UnifiedSessionsSnapshot: Sendable {
  let sessions: [SessionSummary]
  let rootSessions: [RootSessionRecord]
  let sessionRefsByScopedID: [String: SessionRef]
  let endpointHealth: [UnifiedEndpointHealth]
  let counts: UnifiedSessionCounts
}

@MainActor
enum UnifiedSessionsProjection {
  struct EndpointInput {
    let endpoint: ServerEndpoint
    let status: ConnectionStatus
    let rootSessions: [RootSessionRecord]

    init(endpoint: ServerEndpoint, status: ConnectionStatus, rootSessions: [RootSessionRecord]) {
      self.endpoint = endpoint
      self.status = status
      self.rootSessions = rootSessions
    }

    init(endpoint: ServerEndpoint, status: ConnectionStatus, sessions: [Session]) {
      self.init(
        endpoint: endpoint,
        status: status,
        rootSessions: sessions.map { session in
          var decorated = session
          decorated.endpointId = endpoint.id
          decorated.endpointName = endpoint.name
          decorated.endpointConnectionStatus = status
          return decorated.toRootSessionRecord()
        }
      )
    }
  }

  static func snapshot(
    from inputs: [EndpointInput],
    filter: UnifiedEndpointFilter
  ) -> UnifiedSessionsSnapshot {
    let sortedInputs = inputs.sorted { lhs, rhs in
      let lhsName = lhs.endpoint.name.lowercased()
      let rhsName = rhs.endpoint.name.lowercased()
      if lhsName != rhsName {
        return lhsName < rhsName
      }
      return lhs.endpoint.id.uuidString < rhs.endpoint.id.uuidString
    }

    var mergedRootSessions: [RootSessionRecord] = []
    var refsByScopedID: [String: SessionRef] = [:]
    var totalCounts = UnifiedSessionCounts()
    var endpointHealth: [UnifiedEndpointHealth] = []

    for input in sortedInputs {
      let endpoint = input.endpoint
      let endpointRootSessions = sortRootSessions(input.rootSessions)
      let endpointCounts = buildCounts(from: endpointRootSessions)
      endpointHealth.append(
        UnifiedEndpointHealth(
          endpointId: endpoint.id,
          endpointName: endpoint.name,
          status: input.status,
          counts: endpointCounts
        )
      )

      for record in endpointRootSessions {
        let ref = SessionRef(endpointId: endpoint.id, sessionId: record.sessionId)
        if shouldInclude(ref: ref, filter: filter) {
          mergedRootSessions.append(record)
          refsByScopedID[ref.scopedID] = ref
          accumulate(into: &totalCounts, session: record)
        }
      }
    }

    mergedRootSessions.sort(by: compareRootSessions)
    let mergedSessions = mergedRootSessions.map(SessionSummary.init(rootRecord:))

    return UnifiedSessionsSnapshot(
      sessions: mergedSessions,
      rootSessions: mergedRootSessions,
      sessionRefsByScopedID: refsByScopedID,
      endpointHealth: endpointHealth,
      counts: totalCounts
    )
  }

  private static func shouldInclude(ref: SessionRef, filter: UnifiedEndpointFilter) -> Bool {
    switch filter {
      case .all:
        true
      case let .endpoint(endpointId):
        ref.endpointId == endpointId
    }
  }

  private static func compareSessionValues(
    lhsIsActive: Bool,
    rhsIsActive: Bool,
    lhsLastActivityAt: Date?,
    rhsLastActivityAt: Date?,
    lhsStartedAt: Date?,
    rhsStartedAt: Date?,
    lhsDisplayName: String,
    rhsDisplayName: String,
    lhsEndpointName: String?,
    rhsEndpointName: String?,
    lhsId: String,
    rhsId: String
  ) -> Bool {
    if lhsIsActive != rhsIsActive {
      return lhsIsActive && !rhsIsActive
    }

    let lhsDate = lhsLastActivityAt ?? lhsStartedAt ?? .distantPast
    let rhsDate = rhsLastActivityAt ?? rhsStartedAt ?? .distantPast
    if lhsDate != rhsDate {
      return lhsDate > rhsDate
    }

    if lhsDisplayName != rhsDisplayName {
      return lhsDisplayName < rhsDisplayName
    }

    if lhsEndpointName != rhsEndpointName {
      return (lhsEndpointName ?? "") < (rhsEndpointName ?? "")
    }

    return lhsId < rhsId
  }

  private static func buildCounts(from sessions: [RootSessionRecord]) -> UnifiedSessionCounts {
    var counts = UnifiedSessionCounts()
    for session in sessions {
      accumulate(into: &counts, session: session)
    }
    return counts
  }

  private static func accumulate(into counts: inout UnifiedSessionCounts, session: RootSessionRecord) {
    counts.total += 1
    if session.isActive {
      counts.active += 1
      if session.listStatus == .working {
        counts.working += 1
      }
      if session.needsAttention {
        counts.attention += 1
      }
      if session.isReady {
        counts.ready += 1
      }
    }
  }

  private static func compareRootSessions(_ lhs: RootSessionRecord, _ rhs: RootSessionRecord) -> Bool {
    compareSessionValues(
      lhsIsActive: lhs.isActive,
      rhsIsActive: rhs.isActive,
      lhsLastActivityAt: lhs.lastActivityAt,
      rhsLastActivityAt: rhs.lastActivityAt,
      lhsStartedAt: lhs.startedAt,
      rhsStartedAt: rhs.startedAt,
      lhsDisplayName: lhs.displayTitleSortKey,
      rhsDisplayName: rhs.displayTitleSortKey,
      lhsEndpointName: lhs.endpointName,
      rhsEndpointName: rhs.endpointName,
      lhsId: lhs.id,
      rhsId: rhs.id
    )
  }

  private static func sortRootSessions(_ sessions: [RootSessionRecord]) -> [RootSessionRecord] {
    sessions.sorted(by: compareRootSessions)
  }
}

@Observable
@MainActor
final class UnifiedSessionsStore {
  private(set) var selectedEndpointFilter: UnifiedEndpointFilter = .all
  private(set) var sessions: [SessionSummary] = []
  private(set) var rootSessions: [RootSessionRecord] = []
  private(set) var sessionRefsByScopedID: [String: SessionRef] = [:]
  private(set) var endpointHealth: [UnifiedEndpointHealth] = []
  private(set) var counts = UnifiedSessionCounts()

  func setEndpointFilter(_ filter: UnifiedEndpointFilter) {
    selectedEndpointFilter = filter
  }

  func refresh(from inputs: [UnifiedSessionsProjection.EndpointInput]) {
    let snapshot = UnifiedSessionsProjection.snapshot(from: inputs, filter: selectedEndpointFilter)
    sessions = snapshot.sessions
    rootSessions = snapshot.rootSessions
    sessionRefsByScopedID = snapshot.sessionRefsByScopedID
    endpointHealth = snapshot.endpointHealth
    counts = snapshot.counts
  }

  func sessionRef(for scopedID: String) -> SessionRef? {
    if let ref = sessionRefsByScopedID[scopedID] {
      return ref
    }
    return SessionRef(scopedID: scopedID)
  }

  func containsSession(scopedID: String) -> Bool {
    sessionRefsByScopedID[scopedID] != nil
  }
}
