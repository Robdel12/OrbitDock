import Foundation

@MainActor
@Observable
final class MissionListViewModel {
  var missions: [MissionSummary] = []
  var isLoading = true
  var error: String?
  var showNewMission = false
  var actionError: String?

  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?

  func bind(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
  }

  var sessionStore: SessionStore? {
    (runtimeRegistry?.primaryRuntime ?? runtimeRegistry?.activeRuntime)?.sessionStore
  }

  var endpointId: UUID {
    runtimeRegistry?.primaryEndpointId
      ?? runtimeRegistry?.activeEndpointId
      ?? UUID()
  }

  var missionListSnapshot: [MissionSummary] {
    sessionStore?.missionListSnapshot ?? []
  }

  func fetchMissions(using missionsClient: MissionsClient) async {
    isLoading = true
    do {
      let response = try await missionsClient.listMissions()
      missions = response.missions
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
    isLoading = false
  }

  func applyMissionListSnapshotIfNeeded() {
    let snapshot = missionListSnapshot
    guard !snapshot.isEmpty else { return }
    missions = snapshot
  }
}
