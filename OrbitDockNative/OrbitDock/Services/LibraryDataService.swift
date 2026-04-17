import Foundation
import Observation

@Observable
@MainActor
final class LibraryDataService {
  private struct EndpointState {
    let identity: String
    let isDefault: Bool
    var sessionsByScopedID: [String: RootSessionNode] = [:]
    var nextOffset: UInt64?
    var revision: UInt64?
    var loadedPageCount = 0
  }

  private static let defaultPageSize = 200

  private(set) var sessions: [RootSessionNode] = []
  private(set) var hasMoreSessions = false
  private(set) var isLoading = false

  @ObservationIgnored private var endpointStates: [UUID: EndpointState] = [:]
  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?
  @ObservationIgnored private let listenerHub = EndpointListenerHub()
  @ObservationIgnored private let topologyObserver = RuntimeTopologyObserver()
  @ObservationIgnored private let refreshRunner = CoalescedRefreshRunner()
  @ObservationIgnored private var pendingFullRefresh = false
  @ObservationIgnored private var liveConsumerCount = 0

  func refreshNow(runtimeRegistry: ServerRuntimeRegistry) async {
    self.runtimeRegistry = runtimeRegistry
    pendingFullRefresh = true
    scheduleRefreshIfNeeded()
    await refreshRunner.waitForCurrentRefresh()
  }

  func startLiveUpdates(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
    liveConsumerCount += 1
    guard liveConsumerCount == 1 else { return }

    reconcileListeners(runtimeRegistry: runtimeRegistry)
    topologyObserver.start(runtimeRegistry: runtimeRegistry) { [weak self] in
      guard let self, let runtimeRegistry = self.runtimeRegistry else { return }
      self.reconcileListeners(runtimeRegistry: runtimeRegistry)
    }
  }

  func stopLiveUpdates() {
    guard liveConsumerCount > 0 else { return }
    liveConsumerCount -= 1
    guard liveConsumerCount == 0 else { return }

    topologyObserver.stop()
    refreshRunner.cancel()
    pendingFullRefresh = false
    runtimeRegistry = nil
    listenerHub.clear { _, connection in
      connection.unsubscribeArchivedSessions()
    }
  }

  func loadMore(runtimeRegistry: ServerRuntimeRegistry) async {
    guard hasMoreSessions else { return }
    await loadPages(from: runtimeRegistry, reset: false)
  }

  func applyDemoSessions(_ sessions: [RootSessionNode]) {
    endpointStates = Dictionary(grouping: sessions, by: { $0.sessionRef.endpointId })
      .mapValues { groupedSessions in
        let demoIdentity = "demo:\(UUID().uuidString)"
        var state = EndpointState(identity: demoIdentity, isDefault: true)
        for session in groupedSessions {
          state.sessionsByScopedID[session.scopedID] = session
        }
        state.loadedPageCount = 1
        return state
      }
    rebuildSessions()
    hasMoreSessions = false
  }

  private func reconcileListeners(runtimeRegistry: ServerRuntimeRegistry) {
    let enabledRuntimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    let topologyChanged = listenerHub.reconcile(
      runtimes: enabledRuntimes,
      onConnect: { [weak self] endpointId, connection in
        guard let self else { return }
        if connection.connectionStatus == .connected {
          connection.subscribeArchivedSessions(sinceRevision: self.endpointStates[endpointId]?.revision)
        }
      },
      onDisconnect: { [weak self] endpointId, connection in
        connection.unsubscribeArchivedSessions()
        self?.endpointStates.removeValue(forKey: endpointId)
      },
      makeListener: { [weak self] endpointId, connection in
        { [weak self] event in
          guard let self else { return }
          switch event {
            case let .archivedSessionsInvalidated(revision):
              guard self.endpointStates[endpointId]?.revision != revision else { return }
              self.scheduleFullRefresh()

            case let .connectionStatusChanged(status):
              guard status == .connected else { return }
              connection.subscribeArchivedSessions(sinceRevision: self.endpointStates[endpointId]?.revision)

            case let .error(code, _, sessionId):
              guard sessionId == nil, code == "lagged" || code == "replay_oversized" else { return }
              self.scheduleFullRefresh()

            default:
              break
          }
        }
      }
    )

    if topologyChanged {
      scheduleFullRefresh()
    }
  }

  private func scheduleFullRefresh() {
    pendingFullRefresh = true
    scheduleRefreshIfNeeded()
  }

  private func scheduleRefreshIfNeeded() {
    refreshRunner.schedule { [weak self] in
      await self?.performPendingFullRefresh()
    }
  }

  private func performPendingFullRefresh() async {
    guard pendingFullRefresh else { return }
    pendingFullRefresh = false
    guard let runtimeRegistry else { return }
    await loadPages(from: runtimeRegistry, reset: true)
  }

  private func loadPages(from runtimeRegistry: ServerRuntimeRegistry, reset: Bool) async {
    guard !isLoading else {
      if reset {
        pendingFullRefresh = true
      }
      return
    }

    let activeRuntimes = ServerEndpointIdentityPlanner.dedupedRuntimes(
      runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    )
    if activeRuntimes.isEmpty {
      if reset {
        endpointStates.removeAll()
        sessions = []
        hasMoreSessions = false
      }
      return
    }

    isLoading = true
    defer { isLoading = false }

    let activeEndpointIds = Set(activeRuntimes.map(\.endpoint.id))
    endpointStates = endpointStates.filter { activeEndpointIds.contains($0.key) }

    typealias EndpointDescriptor = (
      endpointId: UUID,
      endpointName: String?,
      connectionStatus: ConnectionStatus,
      client: ArchivedSessionsClient,
      identity: String,
      isDefault: Bool,
      currentState: EndpointState,
      offset: UInt64?,
      pagesToLoad: Int
    )
    typealias FetchResult = (endpointId: UUID, state: EndpointState)?

    let descriptors: [EndpointDescriptor] = activeRuntimes.compactMap { runtime in
      let endpointId = runtime.endpoint.id
      let identity = ServerEndpointIdentityPlanner.identity(for: runtime)
      let currentState = endpointStates[endpointId]
        ?? EndpointState(identity: identity, isDefault: runtime.endpoint.isDefault)
      let offset = reset ? 0 : currentState.nextOffset
      let pagesToLoad = reset ? max(currentState.loadedPageCount, 1) : 1
      guard reset || offset != nil else { return nil }
      return (
        endpointId: endpointId,
        endpointName: runtime.endpoint.name,
        connectionStatus: runtime.connection.connectionStatus,
        client: runtime.clients.archivedSessions,
        identity: identity,
        isDefault: runtime.endpoint.isDefault,
        currentState: currentState,
        offset: offset,
        pagesToLoad: pagesToLoad
      )
    }

    let results = await withTaskGroup(of: FetchResult.self) { group in
      for descriptor in descriptors {
        group.addTask {
          let endpointId = descriptor.endpointId
          let endpointName = descriptor.endpointName
          let connectionStatus = descriptor.connectionStatus
          let client = descriptor.client
          let identity = descriptor.identity
          let isDefault = descriptor.isDefault
          let currentState = descriptor.currentState
          let pagesToLoad = descriptor.pagesToLoad

          do {
            var updatedState = currentState
            if reset {
              updatedState.sessionsByScopedID.removeAll()
              updatedState.nextOffset = nil
              updatedState.loadedPageCount = 0
            }

            var nextOffset = descriptor.offset
            for _ in 0..<pagesToLoad {
              let page = try await client.fetchSnapshot(
                limit: Self.defaultPageSize,
                offset: Int(nextOffset ?? 0)
              )
              let mappedSessions = page.sessions.map { item in
                RootSessionNode(
                  session: item,
                  endpointId: endpointId,
                  endpointName: endpointName,
                  connectionStatus: connectionStatus
                )
              }

              for session in mappedSessions {
                updatedState.sessionsByScopedID[session.scopedID] = session
              }
              updatedState.nextOffset = page.nextOffset
              updatedState.revision = page.revision
              updatedState.loadedPageCount += 1

              guard reset, let pageNextOffset = page.nextOffset else { break }
              nextOffset = pageNextOffset
            }

            return (
              endpointId,
              EndpointState(
                identity: identity,
                isDefault: isDefault,
                sessionsByScopedID: updatedState.sessionsByScopedID,
                nextOffset: updatedState.nextOffset,
                revision: updatedState.revision,
                loadedPageCount: updatedState.loadedPageCount
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

    for result in results {
      guard let (endpointId, state) = result else { continue }
      endpointStates[endpointId] = state
    }

    rebuildSessions()
  }

  private func rebuildSessions() {
    let dedupedStates = dedupedEndpointStates()
    sessions = RootSessionSnapshotLoader.sortSessions(
      dedupedStates.flatMap { $0.sessionsByScopedID.values }
    )
    hasMoreSessions = dedupedStates.contains { $0.nextOffset != nil }
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

