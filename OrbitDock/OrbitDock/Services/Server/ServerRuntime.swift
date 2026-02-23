import Foundation

@MainActor
final class ServerRuntime: Identifiable {
  let endpoint: ServerEndpoint
  let connection: ServerConnection
  let appState: ServerAppState

  private(set) var isStarted = false

  init(endpoint: ServerEndpoint, connection: ServerConnection? = nil) {
    self.endpoint = endpoint
    let resolvedConnection = connection ?? ServerConnection(endpoint: endpoint)
    self.connection = resolvedConnection
    self.appState = ServerAppState(connection: resolvedConnection, endpointId: endpoint.id)
    self.appState.setup()
  }

  var id: UUID {
    endpoint.id
  }

  func start() {
    guard endpoint.isEnabled else { return }
    connection.connect(to: endpoint.wsURL)
    isStarted = true
  }

  func stop() {
    connection.disconnect()
    isStarted = false
  }

  func reconnect() {
    connection.disconnect()
    connection.connect(to: endpoint.wsURL)
    isStarted = true
  }

  func suspendInactive() {
    stop()
  }
}
