import Foundation

struct AggregatedMissionSummary: Identifiable, Equatable, Sendable {
  let mission: MissionSummary
  let endpointId: UUID
  let endpointName: String?

  var id: String {
    ref.id
  }

  var ref: MissionRef {
    MissionRef(endpointId: endpointId, missionId: mission.id)
  }
}
