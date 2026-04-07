import Foundation
import Observation

@MainActor
@Observable
final class DashboardViewModel {
  // MARK: - Server state

  private(set) var snapshot: DashboardSnapshot?
  private(set) var presentation: DashboardPresentation?

  // MARK: - Local UI state

  var workbenchFilter: ActiveSessionWorkbenchFilter = .all {
    didSet { rebuildPresentation() }
  }

  var sort: ActiveSessionSort = .recent {
    didSet { rebuildPresentation() }
  }

  var providerFilter: ActiveSessionProviderFilter = .all {
    didSet { rebuildPresentation() }
  }

  var projectFilter: String? {
    didSet { rebuildPresentation() }
  }

  var projectOrder: [String] = {
    guard let data = UserDefaults.standard.data(forKey: "dashboard.projectOrder"),
          let paths = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return paths
  }() {
    didSet {
      if let data = try? JSONEncoder().encode(projectOrder) {
        UserDefaults.standard.set(data, forKey: "dashboard.projectOrder")
      }
      rebuildPresentation()
    }
  }

  // MARK: - Library pagination

  private struct LibraryPaginationState {
    var nextOffset: Int?
    var totalCount: Int?
  }

  @ObservationIgnored private var libraryExtras: [RootSessionNode] = []
  @ObservationIgnored private var libraryPaginationByEndpoint: [UUID: LibraryPaginationState] = [:]
  @ObservationIgnored private var isLoadingLibrary = false
  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?

  // MARK: - Observe (structured concurrency lifecycle)

  private enum DashboardEvent {
    case conversationUpdated(revision: UInt64, item: ServerDashboardConversationItem, endpointId: UUID, endpointName: String?)
    case itemRemoved(sessionId: String, endpointId: UUID)
    case invalidated
  }

  func observe(runtimeRegistry: ServerRuntimeRegistry) async {
    self.runtimeRegistry = runtimeRegistry
    libraryPaginationByEndpoint = runtimeRegistry.runtimes.reduce(into: [:]) { result, runtime in
      guard runtime.endpoint.isEnabled else { return }
      result[runtime.endpoint.id] = LibraryPaginationState(nextOffset: 0, totalCount: nil)
    }

    await refresh(runtimeRegistry: runtimeRegistry)

    let events = AsyncStream<DashboardEvent> { continuation in
      var tokens: [(ServerConnection, ServerConnectionListenerToken)] = []
      for runtime in runtimeRegistry.runtimes where runtime.endpoint.isEnabled {
        let connection = runtime.connection
        let endpointId = runtime.endpoint.id
        let endpointName = runtime.endpoint.name
        if connection.connectionStatus == .connected {
          connection.subscribeDashboard()
        }
        let token = connection.addListener { event in
          switch event {
            case let .dashboardConversationUpdated(revision, item):
              continuation.yield(.conversationUpdated(
                revision: revision, item: item, endpointId: endpointId, endpointName: endpointName
              ))
            case let .dashboardItemRemoved(sessionId):
              continuation.yield(.itemRemoved(sessionId: sessionId, endpointId: endpointId))
            case .dashboardInvalidated:
              continuation.yield(.invalidated)
            case .connectionStatusChanged(.connected):
              connection.subscribeDashboard()
              continuation.yield(.invalidated)
            default:
              break
          }
        }
        tokens.append((connection, token))
      }
      continuation.onTermination = { _ in
        Task { @MainActor in
          for (connection, token) in tokens {
            connection.unsubscribeDashboard()
            connection.removeListener(token)
          }
        }
      }
    }

    for await event in events {
      guard !Task.isCancelled else { break }
      switch event {
        case let .conversationUpdated(revision, item, endpointId, endpointName):
          upsertConversation(revision: revision, item: item, endpointId: endpointId, endpointName: endpointName)
        case let .itemRemoved(sessionId, endpointId):
          removeConversation(sessionId: sessionId, endpointId: endpointId)
        case .invalidated:
          await refresh(runtimeRegistry: runtimeRegistry)
      }
    }
  }

  // MARK: - HTTP refresh

  private func refresh(runtimeRegistry: ServerRuntimeRegistry) async {
    guard !Task.isCancelled else { return }

    let runtimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    guard !runtimes.isEmpty else {
      applySnapshot(DashboardSnapshot(
        revision: 0,
        conversations: [],
        counts: DashboardTriageCounts(),
        directCount: 0,
        hasMultipleEndpoints: false
      ))
      return
    }

    var endpointResults: [DashboardSnapshotMapper.EndpointResult] = []

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
        continue
      }
    }

    let merged = DashboardSnapshotMapper.merge(endpointResults)

    guard merged.revision >= (snapshot?.revision ?? 0) else { return }

    applySnapshot(merged)

    if libraryExtras.isEmpty {
      await loadMoreLibrarySessions(runtimeRegistry: runtimeRegistry)
    }
  }

  func applySnapshot(_ newSnapshot: DashboardSnapshot) {
    snapshot = newSnapshot
    rebuildPresentation()
  }

  // MARK: - Granular mutations

  private func upsertConversation(
    revision: UInt64,
    item: ServerDashboardConversationItem,
    endpointId: UUID,
    endpointName: String?
  ) {
    guard let snapshot else { return }

    let record = DashboardConversationRecord(item: item, endpointId: endpointId, endpointName: endpointName)
    var conversations = snapshot.conversations

    if let index = conversations.firstIndex(where: { $0.id == record.id }) {
      conversations[index] = record
    } else {
      conversations.append(record)
    }

    conversations.sort { lhs, rhs in
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      return lhsDate > rhsDate
    }

    applySnapshot(DashboardSnapshot(
      revision: max(snapshot.revision, revision),
      conversations: conversations,
      counts: DashboardTriageCounts(conversations: conversations),
      directCount: conversations.filter(\.isDirect).count,
      hasMultipleEndpoints: snapshot.hasMultipleEndpoints
    ))
  }

  private func removeConversation(sessionId: String, endpointId: UUID) {
    guard let snapshot else { return }

    let scopedID = SessionRef(endpointId: endpointId, sessionId: sessionId).scopedID
    var conversations = snapshot.conversations
    conversations.removeAll { $0.id == scopedID }

    applySnapshot(DashboardSnapshot(
      revision: snapshot.revision,
      conversations: conversations,
      counts: DashboardTriageCounts(conversations: conversations),
      directCount: conversations.filter(\.isDirect).count,
      hasMultipleEndpoints: snapshot.hasMultipleEndpoints
    ))
  }

  // MARK: - Presentation

  private func rebuildPresentation() {
    guard let snapshot else {
      presentation = nil
      return
    }

    let built = DashboardPresentationBuilder.build(
      snapshot: snapshot,
      filter: workbenchFilter,
      sort: sort,
      providerFilter: providerFilter,
      projectFilter: projectFilter,
      projectOrder: projectOrder
    )
    presentation = built
  }

  // MARK: - Accessors for sub-views

  var rootSessions: [RootSessionNode] {
    RootSessionSnapshotLoader.sortSessions(libraryExtras)
  }

  var dashboardConversations: [DashboardConversationRecord] {
    snapshot?.conversations ?? []
  }

  var dashboardHasMultipleEndpoints: Bool {
    snapshot?.hasMultipleEndpoints ?? false
  }

  var dashboardCounts: DashboardTriageCounts {
    snapshot?.counts ?? DashboardTriageCounts()
  }

  var dashboardDirectCount: Int {
    snapshot?.directCount ?? 0
  }

  var isLoading: Bool {
    snapshot == nil
  }

  // MARK: - Library API

  var librarySessions: [RootSessionNode] {
    rootSessions
  }

  var libraryHasMoreSessions: Bool {
    libraryPaginationByEndpoint.values.contains { $0.nextOffset != nil }
  }

  func loadMoreLibrarySessions(runtimeRegistry: ServerRuntimeRegistry? = nil) async {
    guard let runtimeRegistry = runtimeRegistry ?? self.runtimeRegistry, !isLoadingLibrary else { return }
    isLoadingLibrary = true
    defer { isLoadingLibrary = false }

    let runtimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    for runtime in runtimes {
      let endpointId = runtime.endpoint.id
      guard var pagination = libraryPaginationByEndpoint[endpointId] else { continue }
      guard let offset = pagination.nextOffset else { continue }
      do {
        let page = try await runtime.clients.dashboard.fetchLibrarySnapshot(limit: 200, offset: offset)
        pagination.nextOffset = page.nextOffset.map(Int.init)
        pagination.totalCount = Int(page.totalCount)
        libraryPaginationByEndpoint[endpointId] = pagination

        let connectionStatus = runtime.connection.connectionStatus
        let newSessions = page.sessions.map {
          RootSessionNode(
            session: $0,
            endpointId: endpointId,
            endpointName: runtime.endpoint.name,
            connectionStatus: connectionStatus
          )
        }
        libraryExtras.append(contentsOf: newSessions)
        return
      } catch {
        continue
      }
    }
  }
}
