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
  @ObservationIgnored private var realtimeListenersByEndpoint: [UUID: MissionListRealtimeSubscription] = [:]
  @ObservationIgnored private var realtimeRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var realtimeUpdatesEnabled = false

  func bind(runtimeRegistry: ServerRuntimeRegistry) {
    if self.runtimeRegistry !== runtimeRegistry {
      detachRealtimeListeners()
    }
    self.runtimeRegistry = runtimeRegistry
  }

  func setRealtimeUpdatesEnabled(_ enabled: Bool) {
    guard realtimeUpdatesEnabled != enabled else { return }
    realtimeUpdatesEnabled = enabled
    enabled ? attachRealtimeListeners() : detachRealtimeListeners()
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

  private func sortMissions(_ missions: [AggregatedMissionSummary]) -> [AggregatedMissionSummary] {
    missions.sorted { lhs, rhs in
      let lhsActive = lhs.mission.enabled && !lhs.mission.paused
      let rhsActive = rhs.mission.enabled && !rhs.mission.paused
      if lhsActive != rhsActive { return lhsActive }
      return lhs.mission.name.localizedCaseInsensitiveCompare(rhs.mission.name) == .orderedAscending
    }
  }

  private func attachRealtimeListeners() {
    guard realtimeUpdatesEnabled, let runtimeRegistry else {
      detachRealtimeListeners()
      return
    }

    let enabledRuntimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    let enabledIds = Set(enabledRuntimes.map(\.endpoint.id))

    for (endpointId, subscription) in realtimeListenersByEndpoint where !enabledIds.contains(endpointId) {
      subscription.connection.removeListener(subscription.token)
      realtimeListenersByEndpoint.removeValue(forKey: endpointId)
    }

    for runtime in enabledRuntimes {
      let endpointId = runtime.endpoint.id
      if let existing = realtimeListenersByEndpoint[endpointId], existing.connection !== runtime.connection {
        existing.connection.removeListener(existing.token)
        realtimeListenersByEndpoint.removeValue(forKey: endpointId)
      }

      guard realtimeListenersByEndpoint[endpointId] == nil else { continue }
      let connection = runtime.connection
      let token = connection.addListener { [weak self] event in
        guard let self else { return }
        self.handleRealtimeEvent(event, endpointId: endpointId)
      }
      realtimeListenersByEndpoint[endpointId] = MissionListRealtimeSubscription(
        connection: connection,
        token: token
      )
      if connection.connectionStatus == .connected {
        connection.subscribeMissions()
      }
    }
  }

  private func detachRealtimeListeners() {
    realtimeRefreshTask?.cancel()
    realtimeRefreshTask = nil
    for subscription in realtimeListenersByEndpoint.values {
      subscription.connection.removeListener(subscription.token)
    }
    realtimeListenersByEndpoint.removeAll()
  }

  private func scheduleRealtimeRefresh() {
    guard realtimeRefreshTask == nil else { return }
    realtimeRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.realtimeRefreshTask = nil }
      await self.fetchAllMissions()
    }
  }

  private func handleRealtimeEvent(_ event: ServerEvent, endpointId: UUID) {
    switch event {
      case .missionsInvalidated:
        scheduleRealtimeRefresh()
      case let .connectionStatusChanged(status):
        guard status == .connected else {
          return
        }
        subscribeMissions(for: endpointId)
        scheduleRealtimeRefresh()
      default:
        break
    }
  }

  private func subscribeMissions(for endpointId: UUID) {
    guard let subscription = realtimeListenersByEndpoint[endpointId] else { return }
    subscription.connection.subscribeMissions()
  }
}

private struct MissionListRealtimeSubscription {
  let connection: ServerConnection
  let token: ServerConnectionListenerToken
}
