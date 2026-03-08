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
  let sessions: [Session]
  let sessionRefsByScopedID: [String: SessionRef]
  let endpointHealth: [UnifiedEndpointHealth]
  let counts: UnifiedSessionCounts
}

@MainActor
enum UnifiedSessionsProjection {
  struct EndpointInput {
    let endpoint: ServerEndpoint
    let status: ConnectionStatus
    let sessions: [Session]
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

    var mergedSessions: [Session] = []
    var refsByScopedID: [String: SessionRef] = [:]
    var totalCounts = UnifiedSessionCounts()
    var endpointHealth: [UnifiedEndpointHealth] = []

    for input in sortedInputs {
      let endpoint = input.endpoint
      let normalizedSessions = sortSessions(input.sessions)
      let endpointCounts = buildCounts(from: normalizedSessions)
      endpointHealth.append(
        UnifiedEndpointHealth(
          endpointId: endpoint.id,
          endpointName: endpoint.name,
          status: input.status,
          counts: endpointCounts
        )
      )

      for session in normalizedSessions {
        let ref = SessionRef(endpointId: endpoint.id, sessionId: session.id)
        var decorated = session
        decorated.endpointId = endpoint.id
        decorated.endpointName = endpoint.name
        decorated.endpointConnectionStatus = input.status

        if shouldInclude(ref: ref, filter: filter) {
          mergedSessions.append(decorated)
          refsByScopedID[ref.scopedID] = ref
          accumulate(into: &totalCounts, session: decorated)
        }
      }
    }

    mergedSessions.sort(by: compareSessions)

    return UnifiedSessionsSnapshot(
      sessions: mergedSessions,
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

  private static func sortSessions(_ sessions: [Session]) -> [Session] {
    sessions.sorted(by: compareSessions)
  }

  private static func compareSessions(_ lhs: Session, _ rhs: Session) -> Bool {
    if lhs.isActive != rhs.isActive {
      return lhs.isActive && !rhs.isActive
    }

    let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
    let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
    if lhsDate != rhsDate {
      return lhsDate > rhsDate
    }

    let lhsName = lhs.displayName.lowercased()
    let rhsName = rhs.displayName.lowercased()
    if lhsName != rhsName {
      return lhsName < rhsName
    }

    if lhs.endpointName != rhs.endpointName {
      return (lhs.endpointName ?? "") < (rhs.endpointName ?? "")
    }

    return lhs.id < rhs.id
  }

  private static func buildCounts(from sessions: [Session]) -> UnifiedSessionCounts {
    var counts = UnifiedSessionCounts()
    for session in sessions {
      accumulate(into: &counts, session: session)
    }
    return counts
  }

  private static func accumulate(into counts: inout UnifiedSessionCounts, session: Session) {
    counts.total += 1
    if session.isActive {
      counts.active += 1
      if session.workStatus == .working {
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
}

@Observable
@MainActor
final class UnifiedSessionsStore {
  private let runtimeRegistry: ServerRuntimeRegistry

  private(set) var selectedEndpointFilter: UnifiedEndpointFilter = .all
  private(set) var sessions: [Session] = []
  private(set) var sessionRefsByScopedID: [String: SessionRef] = [:]
  private(set) var endpointHealth: [UnifiedEndpointHealth] = []
  private(set) var counts = UnifiedSessionCounts()

  init(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
  }

  convenience init() {
    self.init(runtimeRegistry: .shared)
  }

  func setEndpointFilter(_ filter: UnifiedEndpointFilter) {
    selectedEndpointFilter = filter
    refresh()
  }

  func refresh() {
    let inputs = runtimeRegistry.runtimes.map { runtime in
      UnifiedSessionsProjection.EndpointInput(
        endpoint: runtime.endpoint,
        status: runtimeRegistry.connectionStatusByEndpointId[runtime.endpoint.id] ?? runtime.connection.status,
        sessions: runtime.appState.sessions
      )
    }

    let snapshot = UnifiedSessionsProjection.snapshot(from: inputs, filter: selectedEndpointFilter)
    sessions = snapshot.sessions
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
