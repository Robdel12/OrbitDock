import Foundation
import Observation

@MainActor
@Observable
final class NotificationSessionMonitor {
  var sessions: [RootSessionNode] = []

  func observe(runtimeRegistry: ServerRuntimeRegistry) async {
    await refreshSessions(runtimeRegistry: runtimeRegistry)

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
      await refreshSessions(runtimeRegistry: runtimeRegistry)
    }
  }

  func applySessions(_ sessions: [RootSessionNode]) {
    self.sessions = RootSessionSnapshotLoader.sortSessions(sessions)
  }

  private func refreshSessions(runtimeRegistry: ServerRuntimeRegistry) async {
    guard !Task.isCancelled else { return }
    applySessions(await RootSessionSnapshotLoader.fetchLibrarySessions(from: runtimeRegistry))
  }
}
