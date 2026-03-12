import Foundation

@Observable
@MainActor
final class RootShellStore {
  private(set) var state = RootShellState()

  var counts: RootShellCounts { state.counts }
  var endpointHealth: [RootShellEndpointHealth] {
    state.endpointHealthByID.values.sorted {
      if $0.endpointName != $1.endpointName {
        return $0.endpointName.localizedCaseInsensitiveCompare($1.endpointName) == .orderedAscending
      }
      return $0.endpointId.uuidString < $1.endpointId.uuidString
    }
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
    state.recordsByScopedID[scopedID]?.sessionRef
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
    return state.orderedScopedIDs.compactMap { scopedID in
      guard let record = state.recordsByScopedID[scopedID] else { return nil }
      switch filter {
        case .all:
          return record
        case let .endpoint(endpointId):
          return record.sessionRef.endpointId == endpointId ? record : nil
      }
    }
  }
}
