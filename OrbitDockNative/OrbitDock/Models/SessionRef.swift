import Foundation

struct SessionRef: Hashable, Identifiable, Codable, Sendable {
  let endpointId: UUID
  let sessionId: String

  nonisolated static let delimiter = "::"

  nonisolated init(endpointId: UUID, sessionId: String) {
    self.endpointId = endpointId
    self.sessionId = sessionId
  }

  nonisolated init?(scopedID: String) {
    guard let split = scopedID.range(of: Self.delimiter) else { return nil }
    let endpointRaw = String(scopedID[..<split.lowerBound])
    let sessionRaw = String(scopedID[split.upperBound...])
    guard let endpointId = UUID(uuidString: endpointRaw), !sessionRaw.isEmpty else { return nil }
    self.init(endpointId: endpointId, sessionId: sessionRaw)
  }

  nonisolated var id: String {
    scopedID
  }

  nonisolated var scopedID: String {
    "\(endpointId.uuidString)\(Self.delimiter)\(sessionId)"
  }
}
