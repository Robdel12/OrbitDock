import Foundation

/// Single connection to one OrbitDock server.
/// Owns the HTTP clients and WebSocket event stream.
@Observable
@MainActor
final class ServerConnection {
  let endpoint: ServerEndpoint
  let clients: ServerClients
  let eventStream: EventStream
  private(set) var connectionStatus: ConnectionStatus = .disconnected

  init(endpoint: ServerEndpoint) {
    self.endpoint = endpoint
    self.clients = ServerClients(
      serverURL: ServerURLResolver.httpBaseURL(from: endpoint.wsURL),
      authToken: endpoint.authToken
    )
    self.eventStream = EventStream(authToken: endpoint.authToken)
    self.eventStream.onEvent = { [weak self] event in
      self?.handleEvent(event)
    }
  }

  func connect() {
    eventStream.connect(to: endpoint.wsURL)
  }

  func reconnectIfNeeded() {
    eventStream.reconnectIfNeeded()
  }

  func disconnect() {
    eventStream.disconnect()
  }

  private func handleEvent(_ event: ServerEvent) {
    if case let .connectionStatusChanged(status) = event {
      connectionStatus = status
    }
  }
}
