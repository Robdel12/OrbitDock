import Foundation
import Observation

@Observable
@MainActor
final class SessionsSummaryDataService {
  private struct EndpointState {
    let identity: String
    let isDefault: Bool
    let revision: UInt64
    let counts: RootShellCounts
    let activeSessions: [RootSessionNode]
    let recentSessions: [RootSessionNode]
  }

  private(set) var counts = RootShellCounts()
  private(set) var activeSessions: [RootSessionNode] = []
  private(set) var recentSessions: [RootSessionNode] = []
  private(set) var summaryRevision: UInt64 = 0

  @ObservationIgnored private var endpointStates: [UUID: EndpointState] = [:]
  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?
  @ObservationIgnored private let listenerHub = EndpointListenerHub()
  @ObservationIgnored private let topologyObserver = RuntimeTopologyObserver()
  @ObservationIgnored private let refreshRunner = CoalescedRefreshRunner()

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
      connection.unsubscribeSessionsSummary()
    }
    endpointStates.removeAll()
    refreshRunner.cancel()
    runtimeRegistry = nil
    counts = RootShellCounts()
    activeSessions = []
    recentSessions = []
    summaryRevision &+= 1
  }

  func refreshNow() async {
    scheduleRefresh()
    await refreshRunner.waitForCurrentRefresh()
  }

  func applyDemoSessions(_ sessions: [RootSessionNode]) {
    let sorted = RootSessionSnapshotLoader.sortSessions(sessions)
    activeSessions = RootSessionSnapshotLoader.missionControlSessions(from: sorted)
    recentSessions = RootSessionSnapshotLoader.recentSessions(from: sorted)
    counts = RootSessionSnapshotLoader.counts(from: sorted)
    summaryRevision &+= 1
  }

  func compactSessions() -> [RootSessionNode] {
    RootSessionSnapshotLoader.sortSessions(dedupeSessions(activeSessions + recentSessions))
  }

  private func reconcileListeners(runtimeRegistry: ServerRuntimeRegistry) {
    let enabledRuntimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    let topologyChanged = listenerHub.reconcile(
      runtimes: enabledRuntimes,
      onConnect: { [weak self] endpointId, connection in
        guard let self else { return }
        if connection.connectionStatus == .connected {
          connection.subscribeSessionsSummary(sinceRevision: self.endpointStates[endpointId]?.revision)
        }
      },
      onDisconnect: { [weak self] endpointId, connection in
        connection.unsubscribeSessionsSummary()
        self?.endpointStates.removeValue(forKey: endpointId)
      },
      makeListener: { [weak self] endpointId, connection in
        { [weak self] event in
          guard let self else { return }
          switch event {
            case .sessionsSummaryInvalidated:
              self.scheduleRefresh()

            case let .connectionStatusChanged(status):
              guard status == .connected else { return }
              connection.subscribeSessionsSummary(sinceRevision: self.endpointStates[endpointId]?.revision)
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

  private func scheduleRefresh() {
    refreshRunner.schedule { [weak self] in
      await self?.refresh()
    }
  }

  private func refresh() async {
    guard !Task.isCancelled, let runtimeRegistry else { return }

    let activeRuntimes = ServerEndpointIdentityPlanner.dedupedRuntimes(
      runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    )
    guard !activeRuntimes.isEmpty else {
      endpointStates.removeAll()
      counts = RootShellCounts()
      activeSessions = []
      recentSessions = []
      summaryRevision &+= 1
      return
    }

    let activeEndpointIds = Set(activeRuntimes.map(\.endpoint.id))
    endpointStates = endpointStates.filter { activeEndpointIds.contains($0.key) }

    typealias EndpointDescriptor = (
      endpointId: UUID,
      endpointName: String?,
      connectionStatus: ConnectionStatus,
      client: SessionsSummaryClient,
      identity: String,
      isDefault: Bool
    )
    typealias FetchResult = (endpointId: UUID, state: EndpointState)?
    let descriptors: [EndpointDescriptor] = activeRuntimes.map { runtime in
      (
        endpointId: runtime.endpoint.id,
        endpointName: runtime.endpoint.name,
        connectionStatus: runtime.connection.connectionStatus,
        client: runtime.clients.sessionsSummary,
        identity: ServerEndpointIdentityPlanner.identity(for: runtime),
        isDefault: runtime.endpoint.isDefault
      )
    }

    let results = await withTaskGroup(of: FetchResult.self) { group in
      for descriptor in descriptors {
        group.addTask {
          do {
            let payload = try await descriptor.client.fetchSnapshot()
            let activeSessions = payload.activeSessions.map { item in
              RootSessionNode(
                session: item,
                endpointId: descriptor.endpointId,
                endpointName: descriptor.endpointName,
                connectionStatus: descriptor.connectionStatus
              )
            }
            let recentSessions = payload.recentSessions.map { item in
              RootSessionNode(
                session: item,
                endpointId: descriptor.endpointId,
                endpointName: descriptor.endpointName,
                connectionStatus: descriptor.connectionStatus
              )
            }

            return (
              descriptor.endpointId,
              EndpointState(
                identity: descriptor.identity,
                isDefault: descriptor.isDefault,
                revision: payload.revision,
                counts: RootShellCounts(
                  total: Int(payload.counts.total),
                  active: Int(payload.counts.active),
                  working: Int(payload.counts.working),
                  attention: Int(payload.counts.attention),
                  ready: Int(payload.counts.ready)
                ),
                activeSessions: activeSessions,
                recentSessions: recentSessions
              )
            )
          } catch {
            return nil
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
      guard let (endpointId, state) = result else { continue }
      endpointStates[endpointId] = state
    }

    rebuildState()
  }

  private func rebuildState() {
    let dedupedEndpointStates = dedupedEndpointStates()
    let allActive = dedupedEndpointStates.flatMap(\.activeSessions)
    let allRecent = dedupedEndpointStates.flatMap(\.recentSessions)
    let allTracked = dedupeSessions(allActive + allRecent)

    activeSessions = RootSessionSnapshotLoader.sortSessions(allActive)
    recentSessions = RootSessionSnapshotLoader.recentSessions(from: allTracked)

    counts = dedupedEndpointStates.reduce(into: RootShellCounts()) { result, state in
      result.total += state.counts.total
      result.active += state.counts.active
      result.working += state.counts.working
      result.attention += state.counts.attention
      result.ready += state.counts.ready
    }
    summaryRevision &+= 1
  }

  private func dedupeSessions(_ sessions: [RootSessionNode]) -> [RootSessionNode] {
    var sessionsByScopedID: [String: RootSessionNode] = [:]
    for session in sessions {
      guard let existing = sessionsByScopedID[session.scopedID] else {
        sessionsByScopedID[session.scopedID] = session
        continue
      }

      sessionsByScopedID[session.scopedID] = preferredTrackedSession(existing, session)
    }
    return Array(sessionsByScopedID.values)
  }

  private func preferredTrackedSession(
    _ existing: RootSessionNode,
    _ candidate: RootSessionNode
  ) -> RootSessionNode {
    if existing.isActive != candidate.isActive {
      return existing.isActive ? existing : candidate
    }

    let existingDate = existing.lastActivityAt ?? existing.startedAt ?? .distantPast
    let candidateDate = candidate.lastActivityAt ?? candidate.startedAt ?? .distantPast
    return candidateDate >= existingDate ? candidate : existing
  }

  private func dedupedEndpointStates() -> [EndpointState] {
    var keptByIdentity: [String: EndpointState] = [:]
    var identityOrder: [String] = []

    for state in endpointStates.values {
      guard let existing = keptByIdentity[state.identity] else {
        keptByIdentity[state.identity] = state
        identityOrder.append(state.identity)
        continue
      }

      if !existing.isDefault && state.isDefault {
        keptByIdentity[state.identity] = state
      }
    }

    return identityOrder.compactMap { keptByIdentity[$0] }
  }
}

