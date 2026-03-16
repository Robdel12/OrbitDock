import Foundation

struct ScopedSessionID: Sendable {
  let endpointId: UUID
  let sessionId: String

  nonisolated static let delimiter = SessionRef.delimiter

  nonisolated init(endpointId: UUID, sessionId: String) {
    self.endpointId = endpointId
    self.sessionId = sessionId
  }

  nonisolated init(sessionRef: SessionRef) {
    self.init(endpointId: sessionRef.endpointId, sessionId: sessionRef.sessionId)
  }

  nonisolated init?(scopedID: String) {
    guard let split = scopedID.range(of: Self.delimiter) else { return nil }
    let endpointRaw = String(scopedID[..<split.lowerBound])
    let sessionRaw = String(scopedID[split.upperBound...])
    guard let endpointId = UUID(uuidString: endpointRaw), !sessionRaw.isEmpty else { return nil }
    self.init(endpointId: endpointId, sessionId: sessionRaw)
  }

  nonisolated var scopedID: String {
    "\(endpointId.uuidString)\(Self.delimiter)\(sessionId)"
  }

  nonisolated static func endpointPrefix(endpointId: UUID) -> String {
    "\(endpointId.uuidString)\(delimiter)"
  }

  nonisolated var sessionRef: SessionRef {
    SessionRef(endpointId: endpointId, sessionId: sessionId)
  }
}

extension ScopedSessionID: Equatable, Hashable {
  func hash(into hasher: inout Hasher) {
    hasher.combine(endpointId)
    hasher.combine(sessionId)
  }
}
