import Foundation

@Observable
@MainActor
final class RootShellStore {
  private(set) var state = RootShellState()

  var counts: RootShellCounts { state.counts }
  var endpointHealth: [RootShellEndpointHealth] {
    state.orderedEndpointIDs.compactMap { state.endpointHealthByID[$0] }
  }

  @discardableResult
  func apply(_ event: RootShellEvent) -> Bool {
    RootShellReducer.reduce(state: &state, event: event)
  }

  @discardableResult
  func replace(with nextState: RootShellState) -> Bool {
    guard state != nextState else { return false }
    state = nextState
    return true
  }

  func sessionRef(for scopedID: ScopedSessionID) -> SessionRef? {
    state.recordsByScopedID[scopedID.scopedID]?.sessionRef
  }

  func sessionRef(for scopedID: String) -> SessionRef? {
    guard let scopedID = ScopedSessionID(scopedID: scopedID) else { return nil }
    return sessionRef(for: scopedID)
  }

  func setEndpointFilter(_ filter: RootShellEndpointFilter) {
    apply(.endpointFilterChanged(filter))
  }

  func records(filter: RootShellEndpointFilter? = nil) -> [RootSessionNode] {
    let filter = filter ?? state.selectedEndpointFilter
    switch filter {
      case .all:
        return state.orderedRecords
      case let .endpoint(endpointId):
        return state.orderedRecords.filter { $0.sessionRef.endpointId == endpointId }
    }
  }

  func missionControlRecords() -> [RootSessionNode] {
    state.missionControlRecords
  }

  func recentRecords(limit: Int? = nil) -> [RootSessionNode] {
    if let limit {
      return Array(state.recentRecords.prefix(limit))
    }
    return state.recentRecords
  }
}
