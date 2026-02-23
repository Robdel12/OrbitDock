import Foundation

struct SessionRef: Hashable, Identifiable, Codable, Sendable {
  let endpointId: UUID
  let sessionId: String

  static let delimiter = "::"

  init(endpointId: UUID, sessionId: String) {
    self.endpointId = endpointId
    self.sessionId = sessionId
  }

  init?(scopedID: String) {
    guard let split = scopedID.range(of: Self.delimiter) else { return nil }
    let endpointRaw = String(scopedID[..<split.lowerBound])
    let sessionRaw = String(scopedID[split.upperBound...])
    guard let endpointId = UUID(uuidString: endpointRaw), !sessionRaw.isEmpty else { return nil }
    self.init(endpointId: endpointId, sessionId: sessionRaw)
  }

  var id: String {
    scopedID
  }

  var scopedID: String {
    "\(endpointId.uuidString)\(Self.delimiter)\(sessionId)"
  }
}
