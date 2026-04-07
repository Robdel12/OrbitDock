import Foundation
import Observation

@Observable
@MainActor
final class DashboardDataService {
  // MARK: - Observable state (consumers read these)

  private(set) var snapshot: DashboardSnapshot?
  private(set) var librarySessions: [RootSessionNode] = []

  // MARK: - Private

  @ObservationIgnored private var listenerTokens: [(ServerConnection, ServerConnectionListenerToken)] = []
  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?
  @ObservationIgnored private var dashboardRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var libraryRefreshTask: Task<Void, Never>?

  // MARK: - Lifecycle

  func start(runtimeRegistry: ServerRuntimeRegistry) {
    guard self.runtimeRegistry == nil else { return }
    self.runtimeRegistry = runtimeRegistry
    attachListeners(runtimeRegistry: runtimeRegistry)
    dashboardRefreshTask = Task { await refreshDashboard() }
    libraryRefreshTask = Task { await refreshLibrary() }
  }

  func stop() {
    for (connection, token) in listenerTokens {
      connection.removeListener(token)
    }
    listenerTokens.removeAll()
    dashboardRefreshTask?.cancel()
    dashboardRefreshTask = nil
    libraryRefreshTask?.cancel()
    libraryRefreshTask = nil
    runtimeRegistry = nil
  }

  // MARK: - Listeners

  private func attachListeners(runtimeRegistry: ServerRuntimeRegistry) {
    for runtime in runtimeRegistry.runtimes where runtime.endpoint.isEnabled {
      let connection = runtime.connection
      let endpointId = runtime.endpoint.id
      let endpointName = runtime.endpoint.name

      if connection.connectionStatus == .connected {
        connection.subscribeDashboard()
      }

      let token = connection.addListener { [weak self] event in
        guard let self else { return }
        switch event {
        case let .dashboardConversationUpdated(revision, item):
          self.applyConversationUpdate(item, revision: revision, endpointId: endpointId, endpointName: endpointName)

        case let .dashboardItemRemoved(sessionId):
          self.removeConversation(sessionId: sessionId, endpointId: endpointId)

        case .dashboardInvalidated:
          self.scheduleDashboardRefresh()

        case .connectionStatusChanged(.connected):
          connection.subscribeDashboard()
          self.scheduleDashboardRefresh()
          self.scheduleLibraryRefresh()

        case let .error(code, _, sessionId) where sessionId == nil:
          switch code {
          case "dashboard_resync_required", "lagged", "replay_oversized":
            self.scheduleDashboardRefresh()
          default:
            break
          }

        default:
          break
        }
      }
      listenerTokens.append((connection, token))
    }
  }

  // MARK: - Incremental updates

  private func applyConversationUpdate(
    _ item: ServerDashboardConversationItem,
    revision: UInt64,
    endpointId: UUID,
    endpointName: String?
  ) {
    guard var current = snapshot else {
      // No snapshot yet — need a full fetch first
      scheduleDashboardRefresh()
      return
    }

    let updatedRecord = DashboardConversationRecord(
      item: item, endpointId: endpointId, endpointName: endpointName
    )

    var conversations = current.conversations
    if let index = conversations.firstIndex(where: {
      $0.sessionId == item.sessionId && $0.sessionRef.endpointId == endpointId
    }) {
      conversations[index] = updatedRecord
    } else {
      conversations.append(updatedRecord)
      scheduleLibraryRefresh()
    }

    conversations.sort { lhs, rhs in
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      return lhsDate > rhsDate
    }

    snapshot = current.replacing(conversations: conversations, revision: max(revision, current.revision))
  }

  private func removeConversation(sessionId: String, endpointId: UUID) {
    guard let current = snapshot else { return }

    let before = current.conversations.count
    var conversations = current.conversations
    conversations.removeAll {
      $0.sessionId == sessionId && $0.sessionRef.endpointId == endpointId
    }

    snapshot = current.replacing(conversations: conversations)

    if conversations.count != before {
      scheduleLibraryRefresh()
    }
  }

  // MARK: - Full refresh (dashboard only)

  private func scheduleDashboardRefresh() {
    dashboardRefreshTask?.cancel()
    dashboardRefreshTask = Task { await refreshDashboard() }
  }

  private func refreshDashboard() async {
    guard !Task.isCancelled, let runtimeRegistry else { return }

    let runtimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    guard !runtimes.isEmpty else {
      snapshot = DashboardSnapshot(
        revision: 0,
        conversations: [],
        counts: DashboardTriageCounts(),
        directCount: 0,
        hasMultipleEndpoints: false
      )
      return
    }

    var endpointResults: [DashboardSnapshotMapper.EndpointResult] = []
    var failedEndpointIds: Set<UUID> = []

    for runtime in runtimes {
      do {
        let payload = try await runtime.clients.dashboard.fetchDashboardSnapshot()
        guard !Task.isCancelled else { return }

        let result = DashboardSnapshotMapper.mapEndpoint(
          payload,
          endpointId: runtime.endpoint.id,
          endpointName: runtime.endpoint.name,
          connectionStatus: runtime.connection.connectionStatus
        )
        endpointResults.append(result)
      } catch {
        failedEndpointIds.insert(runtime.endpoint.id)
        continue
      }
    }

    // Preserve existing conversations for endpoints that failed to refresh
    if let existing = snapshot, !failedEndpointIds.isEmpty {
      let preserved = existing.conversations.filter { failedEndpointIds.contains($0.sessionRef.endpointId) }
      endpointResults.append(DashboardSnapshotMapper.EndpointResult(
        revision: existing.revision,
        conversations: preserved,
        counts: DashboardTriageCounts(conversations: preserved),
        directCount: preserved.filter(\.isDirect).count,
        endpointId: failedEndpointIds.first!
      ))
    }

    let merged = DashboardSnapshotMapper.merge(endpointResults)
    guard merged.revision >= (snapshot?.revision ?? 0) else { return }
    snapshot = merged
  }

  // MARK: - Library refresh (independent lifecycle)

  private func scheduleLibraryRefresh() {
    libraryRefreshTask?.cancel()
    libraryRefreshTask = Task { await refreshLibrary() }
  }

  private func refreshLibrary() async {
    guard !Task.isCancelled, let runtimeRegistry else { return }
    librarySessions = await RootSessionSnapshotLoader.fetchLibrarySessions(from: runtimeRegistry)
  }

  // MARK: - Demo mode

  func applyDemoSnapshot(_ snapshot: DashboardSnapshot) {
    self.snapshot = snapshot
  }

  func applyDemoSessions(_ sessions: [RootSessionNode]) {
    librarySessions = RootSessionSnapshotLoader.sortSessions(sessions)
  }
}
