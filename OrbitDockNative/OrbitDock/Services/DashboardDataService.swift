import Foundation
import Observation

@Observable
@MainActor
final class DashboardDataService {
  // MARK: - Observable state

  private(set) var snapshot: DashboardSnapshot?

  // MARK: - Private

  @ObservationIgnored private var endpointRevisionsByEndpointId: [UUID: UInt64] = [:]
  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?
  @ObservationIgnored private let listenerHub = EndpointListenerHub()
  @ObservationIgnored private let topologyObserver = RuntimeTopologyObserver()
  @ObservationIgnored private let refreshRunner = CoalescedRefreshRunner()

  // MARK: - Lifecycle

  func start(runtimeRegistry: ServerRuntimeRegistry) {
    guard self.runtimeRegistry == nil else { return }
    self.runtimeRegistry = runtimeRegistry
    reconcileListeners(runtimeRegistry: runtimeRegistry)
    topologyObserver.start(runtimeRegistry: runtimeRegistry) { [weak self] in
      guard let self, let runtimeRegistry = self.runtimeRegistry else { return }
      self.reconcileListeners(runtimeRegistry: runtimeRegistry)
    }
    scheduleRefresh()
  }

  func stop() {
    topologyObserver.stop()
    listenerHub.clear { _, connection in
      connection.unsubscribeActiveSessions()
    }
    endpointRevisionsByEndpointId.removeAll()
    refreshRunner.cancel()
    runtimeRegistry = nil
  }

  func refreshNow() async {
    scheduleRefresh()
    await refreshRunner.waitForCurrentRefresh()
  }

  // MARK: - Listener topology

  private func reconcileListeners(runtimeRegistry: ServerRuntimeRegistry) {
    let enabledRuntimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    let topologyChanged = listenerHub.reconcile(
      runtimes: enabledRuntimes,
      onConnect: { [weak self] endpointId, connection in
        guard let self else { return }
        if connection.connectionStatus == .connected {
          connection.subscribeActiveSessions(sinceRevision: self.endpointRevisionsByEndpointId[endpointId])
        }
      },
      onDisconnect: { [weak self] endpointId, connection in
        connection.unsubscribeActiveSessions()
        self?.endpointRevisionsByEndpointId.removeValue(forKey: endpointId)
      },
      makeListener: { [weak self] endpointId, connection in
        { [weak self] event in
          guard let self else { return }
          switch event {
            case .activeSessionsInvalidated:
              self.scheduleRefresh()

            case let .sessionDelta(_, changes) where changes.affectsDashboardProjection:
              self.scheduleRefresh()

            case .connectionStatusChanged(.connected):
              connection.subscribeActiveSessions(sinceRevision: self.endpointRevisionsByEndpointId[endpointId])
              self.scheduleRefresh()

            case let .error(code, _, sessionId):
              guard sessionId == nil, code == "lagged" || code == "replay_oversized" else { return }
              self.scheduleRefresh()

            default:
              break
          }
        }
      }
    )

    if topologyChanged {
      scheduleRefresh()
    }
  }

  // MARK: - Refresh

  private func scheduleRefresh() {
    refreshRunner.schedule { [weak self] in
      await self?.refresh()
    }
  }

  private func refresh() async {
    guard !Task.isCancelled, let runtimeRegistry else { return }

    let runtimes = ServerEndpointIdentityPlanner.dedupedRuntimes(
      runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    )
    guard !runtimes.isEmpty else {
      endpointRevisionsByEndpointId.removeAll()
      snapshot = emptyDashboardSnapshot()
      return
    }

    let activeEndpointIds = Set(runtimes.map(\.endpoint.id))
    endpointRevisionsByEndpointId = endpointRevisionsByEndpointId.filter { activeEndpointIds.contains($0.key) }

    var endpointResults: [DashboardSnapshotMapper.EndpointResult] = []
    var failedEndpointIds: Set<UUID> = []
    var endpointIdentityByEndpointId: [UUID: String] = [:]
    var defaultEndpointById: [UUID: Bool] = [:]

    for runtime in runtimes {
      let endpointId = runtime.endpoint.id
      endpointIdentityByEndpointId[endpointId] = ServerEndpointIdentityPlanner.identity(for: runtime)
      defaultEndpointById[endpointId] = runtime.endpoint.isDefault
    }

    typealias FetchResult = (
      payload: ServerDashboardSnapshotPayload?,
      endpointId: UUID,
      endpointName: String?,
      connectionStatus: ConnectionStatus
    )
    let descriptors = runtimes.map { runtime in
      (
        endpointId: runtime.endpoint.id,
        endpointName: runtime.endpoint.name,
        connectionStatus: runtime.connection.connectionStatus,
        client: runtime.clients.activeSessions
      )
    }

    let results = await withTaskGroup(of: FetchResult.self) { group in
      for descriptor in descriptors {
        group.addTask {
          do {
            let payload = try await descriptor.client.fetchSnapshot()
            return (payload, descriptor.endpointId, descriptor.endpointName, descriptor.connectionStatus)
          } catch {
            return (nil, descriptor.endpointId, descriptor.endpointName, descriptor.connectionStatus)
          }
        }
      }

      var collected: [FetchResult] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    guard !Task.isCancelled else { return }
    for result in results {
      guard let payload = result.payload else {
        failedEndpointIds.insert(result.endpointId)
        continue
      }

      endpointRevisionsByEndpointId[result.endpointId] = payload.revision
      endpointResults.append(
        DashboardSnapshotMapper.mapEndpoint(
          payload,
          endpointId: result.endpointId,
          endpointName: result.endpointName,
          connectionStatus: result.connectionStatus
        )
      )
    }

    let successfulIdentities = Set(endpointResults.map { result in
      endpointIdentity(for: result.endpointId, by: endpointIdentityByEndpointId)
    })
    let failedEndpointIdsWithoutSuccessfulIdentity = failedEndpointIds.filter { endpointId in
      !successfulIdentities.contains(endpointIdentity(for: endpointId, by: endpointIdentityByEndpointId))
    }

    if let existing = snapshot, !failedEndpointIdsWithoutSuccessfulIdentity.isEmpty {
      endpointResults.append(
        contentsOf: preservedResults(for: Set(failedEndpointIdsWithoutSuccessfulIdentity), from: existing)
      )
    }

    let dedupedResults = dedupeEndpointResults(
      endpointResults,
      endpointIdentityByEndpointId: endpointIdentityByEndpointId,
      defaultEndpointById: defaultEndpointById
    )
    snapshot = DashboardSnapshotMapper.merge(dedupedResults)
  }

  private func emptyDashboardSnapshot() -> DashboardSnapshot {
    DashboardSnapshot(
      revision: 0,
      conversations: [],
      counts: DashboardTriageCounts(),
      directCount: 0,
      hasMultipleEndpoints: false,
      projectGroups: []
    )
  }

  private func endpointIdentity(for endpointId: UUID, by endpointIdentityByEndpointId: [UUID: String]) -> String {
    endpointIdentityByEndpointId[endpointId] ?? "endpoint:\(endpointId.uuidString.lowercased())"
  }

  private func preservedResults(
    for failedEndpointIds: Set<UUID>,
    from existing: DashboardSnapshot
  ) -> [DashboardSnapshotMapper.EndpointResult] {
    failedEndpointIds.compactMap { endpointId in
      let conversations = existing.conversations.filter { $0.sessionRef.endpointId == endpointId }
      let projectGroups = existing.projectGroups.filter { $0.endpointId == endpointId }
      guard !conversations.isEmpty || !projectGroups.isEmpty else { return nil }

      return DashboardSnapshotMapper.EndpointResult(
        revision: existing.revision,
        conversations: conversations,
        counts: DashboardTriageCounts(conversations: conversations),
        directCount: conversations.filter(\.isDirect).count,
        endpointId: endpointId,
        projectGroups: projectGroups
      )
    }
  }

  private func dedupeEndpointResults(
    _ results: [DashboardSnapshotMapper.EndpointResult],
    endpointIdentityByEndpointId: [UUID: String],
    defaultEndpointById: [UUID: Bool]
  ) -> [DashboardSnapshotMapper.EndpointResult] {
    var keptByIdentity: [String: DashboardSnapshotMapper.EndpointResult] = [:]
    var identityOrder: [String] = []

    for result in results {
      let identity = endpointIdentity(for: result.endpointId, by: endpointIdentityByEndpointId)
      guard let existing = keptByIdentity[identity] else {
        keptByIdentity[identity] = result
        identityOrder.append(identity)
        continue
      }

      let existingIsDefault = defaultEndpointById[existing.endpointId] == true
      let candidateIsDefault = defaultEndpointById[result.endpointId] == true
      if !existingIsDefault && candidateIsDefault {
        keptByIdentity[identity] = result
      }
    }

    return identityOrder.compactMap { keptByIdentity[$0] }
  }

  // MARK: - Demo mode

  func applyDemoSnapshot(_ snapshot: DashboardSnapshot) {
    self.snapshot = snapshot
  }
}

private extension ServerStateChanges {
  var affectsDashboardProjection: Bool {
    status != nil
      || workStatus != nil
      || controlMode != nil
      || lifecycleState != nil
      || pendingApproval != nil
      || currentDiff != nil
      || cumulativeDiff != nil
      || customName != nil
      || summary != nil
      || codexIntegrationMode != nil
      || claudeIntegrationMode != nil
      || lastActivityAt != nil
      || firstPrompt != nil
      || lastMessage != nil
      || model != nil
      || effort != nil
      || gitBranch != nil
      || currentCwd != nil
      || repositoryRoot != nil
      || isWorktree != nil
      || unreadCount != nil
  }
}
