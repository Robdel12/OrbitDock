import Foundation

struct MissionRef: Hashable, Identifiable, Sendable {
  let endpointId: UUID
  let missionId: String

  nonisolated var id: String {
    "\(endpointId)::\(missionId)"
  }
}
