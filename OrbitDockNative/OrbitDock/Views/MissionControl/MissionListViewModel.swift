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
  @ObservationIgnored private var refreshTasksByEndpoint: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var missionRevisionByEndpoint: [UUID: UInt64] = [:]
  @ObservationIgnored private var realtimeUpdatesEnabled = false

  func activate(runtimeRegistry: ServerRuntimeRegistry) async {
    bind(runtimeRegistry: runtimeRegistry)
    setRealtimeUpdatesEnabled(true)
    await fetchAllMissions()
  }

  func deactivate() {
    setRealtimeUpdatesEnabled(false)
  }

  func bind(runtimeRegistry: ServerRuntimeRegistry) {
    if self.runtimeRegistry !== runtimeRegistry {
      detachRealtimeListeners()
      missionRevisionByEndpoint.removeAll()
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
    let enabledRuntimes = ServerEndpointIdentityPlanner.dedupedRuntimes(
      registry.runtimes.filter(\.endpoint.isEnabled)
    )
    let isInitialLoad = missions.isEmpty
    if isInitialLoad {
      isLoading = true
    }

    let results = await loadMissionSnapshots(from: enabledRuntimes)
    applyMissionSnapshots(results, preserveExistingOnFailure: !isInitialLoad)

    if isInitialLoad {
      isLoading = false
    }
  }

  func handleMissionCreated(
    _ mission: MissionSummary,
    endpointId: UUID,
    endpointName: String?
  ) {
    missions.insert(
      AggregatedMissionSummary(
        mission: mission,
        endpointId: endpointId,
        endpointName: endpointName
      ),
      at: 0
    )
    missions = sortMissions(missions)
  }

  func applyMissionList(
    _ response: ServerMissionSnapshotPayload,
    endpointId: UUID,
    endpointName: String?
  ) {
    missionRevisionByEndpoint[endpointId] = response.revision
    let updatedMissions = response.missions.map { mission in
      AggregatedMissionSummary(
        mission: mission,
        endpointId: endpointId,
        endpointName: endpointName
      )
    }
    missions.removeAll { $0.endpointId == endpointId }
    missions.append(contentsOf: updatedMissions)
    missions = sortMissions(missions)
  }

  func applyMissionList(
    _ response: MissionsListResponse,
    endpointId: UUID,
    endpointName: String?
  ) {
    let updatedMissions = response.missions.map { mission in
      AggregatedMissionSummary(
        mission: mission,
        endpointId: endpointId,
        endpointName: endpointName
      )
    }
    missions.removeAll { $0.endpointId == endpointId }
    missions.append(contentsOf: updatedMissions)
    missions = sortMissions(missions)
  }

  private func sortMissions(_ missions: [AggregatedMissionSummary]) -> [AggregatedMissionSummary] {
    missions.sorted { lhs, rhs in
      let lhsActive = lhs.mission.enabled && !lhs.mission.paused
      let rhsActive = rhs.mission.enabled && !rhs.mission.paused
      if lhsActive != rhsActive { return lhsActive }
      return lhs.mission.name.localizedCaseInsensitiveCompare(rhs.mission.name) == .orderedAscending
    }
  }

  private func loadMissionSnapshots(
    from runtimes: [ServerRuntime]
  ) async -> [EndpointMissionSnapshot] {
    await withTaskGroup(of: EndpointMissionSnapshot?.self) { group in
      for runtime in runtimes {
        group.addTask { [endpointId = runtime.endpoint.id, endpointName = runtime.endpoint.name] in
          do {
            let snapshot = try await runtime.clients.missions.fetchMissionSnapshot()
            let aggregated = snapshot.missions.map { mission in
              AggregatedMissionSummary(
                mission: mission,
                endpointId: endpointId,
                endpointName: endpointName
              )
            }
            return EndpointMissionSnapshot(
              endpointId: endpointId,
              revision: snapshot.revision,
              missions: aggregated
            )
          } catch {
            return nil
          }
        }
      }

      var snapshots: [EndpointMissionSnapshot] = []
      for await snapshot in group {
        if let snapshot {
          snapshots.append(snapshot)
        }
      }
      return snapshots
    }
  }

  private func applyMissionSnapshots(
    _ snapshots: [EndpointMissionSnapshot],
    preserveExistingOnFailure: Bool
  ) {
    guard !snapshots.isEmpty else {
      if !preserveExistingOnFailure {
        missions = []
        error = "Failed to load missions."
      }
      return
    }

    missionRevisionByEndpoint.merge(
      Dictionary(uniqueKeysWithValues: snapshots.map { ($0.endpointId, $0.revision) }),
      uniquingKeysWith: { _, new in new }
    )

    let loadedMissions = snapshots.flatMap(\.missions)
    missions = sortMissions(loadedMissions)
    error = nil
  }

  private func attachRealtimeListeners() {
    guard realtimeUpdatesEnabled, let runtimeRegistry else {
      detachRealtimeListeners()
      return
    }

    let enabledRuntimes = ServerEndpointIdentityPlanner.dedupedRuntimes(
      runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    )
    let enabledIds = Set(enabledRuntimes.map(\.endpoint.id))

    for (endpointId, subscription) in realtimeListenersByEndpoint where !enabledIds.contains(endpointId) {
      subscription.connection.unsubscribeMissions()
      subscription.connection.removeListener(subscription.token)
      realtimeListenersByEndpoint.removeValue(forKey: endpointId)
    }

    for runtime in enabledRuntimes {
      let endpointId = runtime.endpoint.id
      if let existing = realtimeListenersByEndpoint[endpointId], existing.connection !== runtime.connection {
        existing.connection.unsubscribeMissions()
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
        connection.subscribeMissions(sinceRevision: missionRevisionByEndpoint[endpointId])
      }
    }
  }

  private func detachRealtimeListeners() {
    for task in refreshTasksByEndpoint.values {
      task.cancel()
    }
    refreshTasksByEndpoint.removeAll()
    for subscription in realtimeListenersByEndpoint.values {
      subscription.connection.unsubscribeMissions()
      subscription.connection.removeListener(subscription.token)
    }
    realtimeListenersByEndpoint.removeAll()
  }

  private func scheduleRealtimeRefresh(for endpointId: UUID) {
    guard refreshTasksByEndpoint[endpointId] == nil else { return }
    refreshTasksByEndpoint[endpointId] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.refreshTasksByEndpoint[endpointId] = nil }
      await self.refreshEndpointMissions(endpointId: endpointId)
    }
  }

  private func handleRealtimeEvent(_ event: ServerEvent, endpointId: UUID) {
    switch event {
      case .missionsInvalidated:
        scheduleRealtimeRefresh(for: endpointId)
      case let .connectionStatusChanged(status):
        guard status == .connected else {
          return
        }
        subscribeMissions(for: endpointId)
        scheduleRealtimeRefresh(for: endpointId)
      default:
        break
    }
  }

  private func subscribeMissions(for endpointId: UUID) {
    guard let subscription = realtimeListenersByEndpoint[endpointId] else { return }
    subscription.connection.subscribeMissions(
      sinceRevision: missionRevisionByEndpoint[endpointId]
    )
  }

  private func refreshEndpointMissions(endpointId: UUID) async {
    guard let registry = runtimeRegistry else { return }
    guard let runtime = registry.runtimesByEndpointId[endpointId] else { return }
    guard runtime.endpoint.isEnabled else { return }

    do {
      let snapshot = try await runtime.clients.missions.fetchMissionSnapshot()
      applyMissionList(
        ServerMissionSnapshotPayload(
          revision: snapshot.revision,
          missions: snapshot.missions
        ),
        endpointId: endpointId,
        endpointName: runtime.endpoint.name
      )
      error = nil

      if let subscription = realtimeListenersByEndpoint[endpointId] {
        subscription.connection.subscribeMissions(sinceRevision: snapshot.revision)
      }
    } catch let refreshError {
      if missions.isEmpty {
        error = refreshError.localizedDescription
      }
    }
  }
}

private struct MissionListRealtimeSubscription {
  let connection: ServerConnection
  let token: ServerConnectionListenerToken
}

private struct EndpointMissionSnapshot: Sendable {
  let endpointId: UUID
  let revision: UInt64
  let missions: [AggregatedMissionSummary]
}
