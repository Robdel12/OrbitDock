import Foundation

actor SessionRegistry {
  private let hotSessionLimit: Int
  private var hotSessionIDs: Set<String> = []
  private var hotSessionOrder: [String] = []

  init(hotSessionLimit: Int = 3) {
    self.hotSessionLimit = max(hotSessionLimit, 1)
  }

  func promote(_ sessionID: ScopedSessionID) {
    let scopedID = sessionID.scopedID
    hotSessionIDs.insert(scopedID)
    hotSessionOrder.removeAll { $0 == scopedID }
    hotSessionOrder.append(scopedID)

    while hotSessionOrder.count > hotSessionLimit {
      let evicted = hotSessionOrder.removeFirst()
      hotSessionIDs.remove(evicted)
    }
  }

  func demote(_ sessionID: ScopedSessionID) {
    let scopedID = sessionID.scopedID
    hotSessionIDs.remove(scopedID)
    hotSessionOrder.removeAll { $0 == scopedID }
  }

  func isHot(_ sessionID: ScopedSessionID) -> Bool {
    hotSessionIDs.contains(sessionID.scopedID)
  }

  func hotSessionIDsSnapshot() -> Set<String> {
    hotSessionIDs
  }

  func hotSessionOrderSnapshot() -> [String] {
    hotSessionOrder
  }
}
