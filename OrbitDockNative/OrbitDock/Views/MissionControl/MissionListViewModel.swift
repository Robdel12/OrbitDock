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
  @ObservationIgnored private weak var missionProjectionStore: MissionProjectionStore?

  func bind(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
    self.missionProjectionStore = runtimeRegistry.missionProjectionStore
  }

  var projectedMissionsSnapshot: [AggregatedMissionSummary] {
    missionProjectionStore?.missions ?? []
  }

  func fetchAllMissions() async {
    guard let registry = runtimeRegistry else { return }
    isLoading = true
    var all: [AggregatedMissionSummary] = []

    for runtime in registry.runtimes where runtime.endpoint.isEnabled {
      let endpointId = runtime.endpoint.id
      let endpointName = runtime.endpoint.name
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

    missions = sortMissions(all)

    error = missions.isEmpty && all.isEmpty ? nil : nil
    isLoading = false
  }

  func applyMissionListSnapshotIfNeeded() {
    let snapshot = projectedMissionsSnapshot
    guard !snapshot.isEmpty else { return }
    missions = mergeMissions(current: missions, incoming: snapshot)
  }

  private func mergeMissions(
    current: [AggregatedMissionSummary],
    incoming: [AggregatedMissionSummary]
  ) -> [AggregatedMissionSummary] {
    var mergedByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    for mission in incoming {
      mergedByID[mission.id] = mission
    }
    return sortMissions(Array(mergedByID.values))
  }

  private func sortMissions(_ missions: [AggregatedMissionSummary]) -> [AggregatedMissionSummary] {
    missions.sorted { lhs, rhs in
      let lhsActive = lhs.mission.enabled && !lhs.mission.paused
      let rhsActive = rhs.mission.enabled && !rhs.mission.paused
      if lhsActive != rhsActive { return lhsActive }
      return lhs.mission.name.localizedCaseInsensitiveCompare(rhs.mission.name) == .orderedAscending
    }
  }
}
