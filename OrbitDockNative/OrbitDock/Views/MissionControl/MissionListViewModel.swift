import Foundation

@MainActor
@Observable
final class MissionListViewModel {
  var missions: [AggregatedMissionSummary] = []
  var isLoading = true
  var error: String?
  var showNewMission = false
  var actionError: String?

  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?

  func bind(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
  }

  var aggregatedMissionsSnapshot: [AggregatedMissionSummary] {
    runtimeRegistry?.aggregatedMissions ?? []
  }

  func fetchAllMissions() async {
    guard let registry = runtimeRegistry else { return }
    isLoading = true
    var all: [AggregatedMissionSummary] = []

    for runtime in registry.runtimes where runtime.endpoint.isEnabled {
      let endpointId = runtime.endpoint.id
      let endpointName = runtime.endpoint.name
      let status = registry.connectionStatusByEndpointId[endpointId]
      guard status == .connected else { continue }
      do {
        let response = try await runtime.clients.missions.listMissions()
        let aggregated = response.missions.map { mission in
          AggregatedMissionSummary(mission: mission, endpointId: endpointId, endpointName: endpointName)
        }
        all.append(contentsOf: aggregated)
      } catch {
        // Individual endpoint failure shouldn't block others
        continue
      }
    }

    missions = all.sorted { lhs, rhs in
      let lhsActive = lhs.mission.enabled && !lhs.mission.paused
      let rhsActive = rhs.mission.enabled && !rhs.mission.paused
      if lhsActive != rhsActive { return lhsActive }
      return lhs.mission.name.localizedCaseInsensitiveCompare(rhs.mission.name) == .orderedAscending
    }

    error = missions.isEmpty && all.isEmpty ? nil : nil
    isLoading = false
  }

  func applyMissionListSnapshotIfNeeded() {
    let snapshot = aggregatedMissionsSnapshot
    guard !snapshot.isEmpty else { return }
    missions = snapshot
  }
}
