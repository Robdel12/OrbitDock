import Foundation

@Observable
@MainActor
final class RootShellStore {
  private(set) var counts = RootShellCounts()
  private(set) var endpointHealthRecords: [RootShellEndpointHealth] = []
  private(set) var orderedRecordsStorage: [RootSessionNode] = []
  private(set) var missionControlRecordsStorage: [RootSessionNode] = []
  private(set) var recentRecordsStorage: [RootSessionNode] = []
  private(set) var selectedEndpointFilter: RootShellEndpointFilter = .all

  @ObservationIgnored private var state = RootShellState()

  var endpointHealth: [RootShellEndpointHealth] {
    endpointHealthRecords
  }

  @discardableResult
  func apply(_ event: RootShellEvent) -> Bool {
    apply([event]).didChange
  }

  @discardableResult
  func apply(_ events: [RootShellEvent]) -> RootShellChangeSet {
    guard !events.isEmpty else { return RootShellChangeSet() }

    let previousState = state
    var nextState = state
    let changed = RootShellReducer.reduce(state: &nextState, events: events)
    guard changed else { return RootShellChangeSet() }

    state = nextState
    syncPublishedState(from: nextState)

    return diff(previous: previousState, next: nextState)
  }

  func sessionRef(for scopedID: ScopedSessionID) -> SessionRef? {
    state.recordsByScopedID[scopedID.scopedID]?.sessionRef
  }

  func sessionRef(for scopedID: String) -> SessionRef? {
    guard let scopedID = ScopedSessionID(scopedID: scopedID) else { return nil }
    return sessionRef(for: scopedID)
  }

  func record(for scopedID: String) -> RootSessionNode? {
    state.recordsByScopedID[scopedID]
  }

  func setEndpointFilter(_ filter: RootShellEndpointFilter) {
    apply(.endpointFilterChanged(filter))
  }

  func records(filter: RootShellEndpointFilter? = nil) -> [RootSessionNode] {
    let filter = filter ?? selectedEndpointFilter
    switch filter {
      case .all:
        return orderedRecordsStorage
      case let .endpoint(endpointId):
        return orderedRecordsStorage.filter { $0.sessionRef.endpointId == endpointId }
    }
  }

  func missionControlRecords() -> [RootSessionNode] {
    missionControlRecordsStorage
  }

  func recentRecords(limit: Int? = nil) -> [RootSessionNode] {
    if let limit {
      return Array(recentRecordsStorage.prefix(limit))
    }
    return recentRecordsStorage
  }

  private func syncPublishedState(from state: RootShellState) {
    counts = state.counts
    endpointHealthRecords = state.orderedEndpointIDs.compactMap { state.endpointHealthByID[$0] }
    orderedRecordsStorage = state.orderedRecords
    missionControlRecordsStorage = state.missionControlRecords
    recentRecordsStorage = state.recentRecords
    selectedEndpointFilter = state.selectedEndpointFilter
  }

  private func diff(previous: RootShellState, next: RootShellState) -> RootShellChangeSet {
    let previousRecords = previous.recordsByScopedID
    let nextRecords = next.recordsByScopedID

    let upsertedScopedIDs = next.orderedScopedIDs.filter { scopedID in
      previousRecords[scopedID] != nextRecords[scopedID]
    }

    let removedScopedIDs = previous.orderedScopedIDs.filter { scopedID in
      nextRecords[scopedID] == nil
    }

    return RootShellChangeSet(
      upsertedScopedIDs: upsertedScopedIDs,
      removedScopedIDs: removedScopedIDs,
      didChange: true
    )
  }
}
