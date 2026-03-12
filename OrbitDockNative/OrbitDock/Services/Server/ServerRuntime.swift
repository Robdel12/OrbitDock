import Foundation

@MainActor
final class ServerRuntime: Identifiable {
  let endpoint: ServerEndpoint
  let clients: ServerClients
  let controlPlaneClient: ControlPlaneClient
  let eventStream: EventStream
  let sessionStore: SessionStore

  private(set) var isStarted = false

  init(endpoint: ServerEndpoint) {
    self.endpoint = endpoint
    self.clients = ServerClients(
      serverURL: ServerURLResolver.httpBaseURL(from: endpoint.wsURL),
      authToken: endpoint.authToken
    )
    self.controlPlaneClient = clients.controlPlane
    self.eventStream = EventStream(authToken: endpoint.authToken)
    self.sessionStore = SessionStore(
      clients: clients,
      eventStream: eventStream,
      endpointId: endpoint.id,
      endpointName: endpoint.name
    )
  }

  init(
    endpoint: ServerEndpoint,
    clients: ServerClients,
    controlPlaneClient: ControlPlaneClient? = nil,
    eventStream: EventStream,
    sessionStore: SessionStore? = nil
  ) {
    self.endpoint = endpoint
    self.clients = clients
    self.controlPlaneClient = controlPlaneClient ?? clients.controlPlane
    self.eventStream = eventStream
    self.sessionStore = sessionStore
      ?? SessionStore(
        clients: clients,
        eventStream: eventStream,
        endpointId: endpoint.id,
        endpointName: endpoint.name
      )
  }

  var id: UUID {
    endpoint.id
  }

  var controlPlanePort: ServerControlPlanePort {
    return ServerControlPlanePort(
      endpointId: endpoint.id,
      client: controlPlaneClient
    )
  }

  var readiness: ServerRuntimeReadiness {
    ServerRuntimeReadiness.derive(
      connectionStatus: eventStream.connectionStatus,
      hasReceivedInitialRootList: eventStream.hasReceivedInitialSessionsList
    )
  }

  func start() {
    guard endpoint.isEnabled else { return }
    guard !isStarted else { return }
    sessionStore.startProcessingEvents()
    eventStream.connect(to: endpoint.wsURL)
    isStarted = true
  }

  func stop() {
    guard isStarted else { return }
    eventStream.disconnect()
    sessionStore.stopProcessingEvents()
    isStarted = false
  }

  func reconnect() {
    guard endpoint.isEnabled else { return }
    stop()
    sessionStore.startProcessingEvents()
    eventStream.connect(to: endpoint.wsURL)
    isStarted = true
  }

  func reconnectIfNeeded() {
    guard isStarted else { return }
    eventStream.reconnectIfNeeded()
  }

  func suspendInactive() {
    stop()
  }
}
