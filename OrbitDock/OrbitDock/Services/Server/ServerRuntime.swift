import Foundation

@MainActor
final class ServerRuntime: Identifiable {
  let endpoint: ServerEndpoint
  let apiClient: APIClient
  let controlPlaneClient: ControlPlaneClient
  let eventStream: EventStream
  let sessionStore: SessionStore

  private(set) var isStarted = false

  init(endpoint: ServerEndpoint) {
    self.endpoint = endpoint
    self.apiClient = APIClient(
      serverURL: APIClient.httpBaseURL(from: endpoint.wsURL),
      authToken: endpoint.authToken
    )
    self.controlPlaneClient = .live(apiClient: apiClient)
    self.eventStream = EventStream(authToken: endpoint.authToken)
    self.sessionStore = SessionStore(
      apiClient: apiClient,
      eventStream: eventStream,
      endpointId: endpoint.id,
      endpointName: endpoint.name
    )
  }

  init(
    endpoint: ServerEndpoint,
    apiClient: APIClient,
    controlPlaneClient: ControlPlaneClient? = nil,
    eventStream: EventStream,
    sessionStore: SessionStore? = nil
  ) {
    self.endpoint = endpoint
    self.apiClient = apiClient
    self.controlPlaneClient = controlPlaneClient ?? .live(apiClient: apiClient)
    self.eventStream = eventStream
    self.sessionStore = sessionStore
      ?? SessionStore(
        apiClient: apiClient,
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
      hasReceivedInitialSessionsList: sessionStore.hasReceivedInitialSessionsList
    )
  }

  func start() {
    guard endpoint.isEnabled else { return }
    sessionStore.startProcessingEvents()
    eventStream.connect(to: endpoint.wsURL)
    isStarted = true
  }

  func stop() {
    eventStream.disconnect()
    sessionStore.stopProcessingEvents()
    isStarted = false
  }

  func reconnect() {
    eventStream.disconnect()
    eventStream.connect(to: endpoint.wsURL)
    isStarted = true
  }

  func suspendInactive() {
    stop()
  }
}
