import Foundation

actor SessionRegistry {
  private var hotSessionIDs: Set<String> = []

  func promote(_ sessionID: ScopedSessionID) {
    hotSessionIDs.insert(sessionID.scopedID)
  }

  func demote(_ sessionID: ScopedSessionID) {
    hotSessionIDs.remove(sessionID.scopedID)
  }

  func isHot(_ sessionID: ScopedSessionID) -> Bool {
    hotSessionIDs.contains(sessionID.scopedID)
  }

  func hotSessionIDsSnapshot() -> Set<String> {
    hotSessionIDs
  }
}
