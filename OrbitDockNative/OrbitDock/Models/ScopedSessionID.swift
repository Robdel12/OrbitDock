import Foundation

struct ScopedSessionID: Hashable, Sendable {
  let endpointId: UUID
  let sessionId: String

  static let delimiter = SessionRef.delimiter

  init(endpointId: UUID, sessionId: String) {
    self.endpointId = endpointId
    self.sessionId = sessionId
  }

  init(sessionRef: SessionRef) {
    self.init(endpointId: sessionRef.endpointId, sessionId: sessionRef.sessionId)
  }

  init?(scopedID: String) {
    guard let split = scopedID.range(of: Self.delimiter) else { return nil }
    let endpointRaw = String(scopedID[..<split.lowerBound])
    let sessionRaw = String(scopedID[split.upperBound...])
    guard let endpointId = UUID(uuidString: endpointRaw), !sessionRaw.isEmpty else { return nil }
    self.init(endpointId: endpointId, sessionId: sessionRaw)
  }

  var scopedID: String {
    "\(endpointId.uuidString)\(Self.delimiter)\(sessionId)"
  }

  var sessionRef: SessionRef {
    SessionRef(endpointId: endpointId, sessionId: sessionId)
  }
}

extension ScopedSessionID {
  nonisolated static func == (lhs: ScopedSessionID, rhs: ScopedSessionID) -> Bool {
    lhs.endpointId == rhs.endpointId && lhs.sessionId == rhs.sessionId
  }

  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(endpointId)
    hasher.combine(sessionId)
  }
}
