import Foundation
import Observation

@MainActor
@Observable
final class MenuBarViewModel {
  var snapshot = MenuBarSnapshot.empty

  @ObservationIgnored private weak var runtimeRegistry: ServerRuntimeRegistry?

  func observe(runtimeRegistry: ServerRuntimeRegistry) async {
    self.runtimeRegistry = runtimeRegistry
    await refreshSnapshot(runtimeRegistry: runtimeRegistry)

    let invalidations = AsyncStream<Void> { continuation in
      var tokens: [(ServerConnection, ServerConnectionListenerToken)] = []
      for runtime in runtimeRegistry.runtimes where runtime.endpoint.isEnabled {
        let connection = runtime.connection
        if connection.connectionStatus == .connected {
          connection.subscribeDashboard()
        }
        let token = connection.addListener { event in
          switch event {
            case .dashboardInvalidated, .dashboardConversationUpdated, .dashboardItemRemoved:
              continuation.yield()
            case .connectionStatusChanged(.connected):
              connection.subscribeDashboard()
              continuation.yield()
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

    for await _ in invalidations {
      guard !Task.isCancelled else { break }
      await refreshSnapshot(runtimeRegistry: runtimeRegistry)
    }
  }

  func refreshSnapshot() async {
    guard let runtimeRegistry else { return }
    await refreshSnapshot(runtimeRegistry: runtimeRegistry)
  }

  func applySessions(_ sessions: [RootSessionNode]) {
    snapshot = MenuBarSnapshot(
      activeSessions: RootSessionSnapshotLoader.missionControlSessions(from: sessions, limit: 8),
      recentSessions: RootSessionSnapshotLoader.recentSessions(from: sessions, limit: 5),
      totalCount: RootSessionSnapshotLoader.counts(from: sessions).total
    )
  }

  private func refreshSnapshot(runtimeRegistry: ServerRuntimeRegistry) async {
    guard !Task.isCancelled else { return }
    applySessions(await RootSessionSnapshotLoader.fetchLibrarySessions(from: runtimeRegistry))
  }
}
