import Foundation

struct SessionRegistrySnapshot: Equatable, Sendable {
  let state: RootShellState
  let hotSessionIDs: Set<ScopedSessionID>

  var records: [RootSessionNode] {
    state.orderedScopedIDs.compactMap { state.recordsByScopedID[$0] }
  }
}

actor SessionRegistry {
  private var state = RootShellState()
  private var hotSessionIDs: Set<ScopedSessionID> = []

  @discardableResult
  func apply(_ event: RootShellEvent) -> Bool {
    RootShellReducer.reduce(state: &state, event: event)
  }

  func promote(_ sessionID: ScopedSessionID) {
    hotSessionIDs.insert(sessionID)
  }

  func demote(_ sessionID: ScopedSessionID) {
    hotSessionIDs.remove(sessionID)
  }

  func isHot(_ sessionID: ScopedSessionID) -> Bool {
    hotSessionIDs.contains(sessionID)
  }

  func snapshot() -> SessionRegistrySnapshot {
    SessionRegistrySnapshot(
      state: state,
      hotSessionIDs: hotSessionIDs
    )
  }
}
