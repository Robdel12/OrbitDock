import Foundation

@MainActor
final class ServerRuntime: Identifiable {
  let endpoint: ServerEndpoint
  let apiClient: APIClient
  let eventStream: EventStream
  let sessionStore: SessionStore

  private(set) var isStarted = false

  init(endpoint: ServerEndpoint) {
    self.endpoint = endpoint
    self.apiClient = APIClient(
      serverURL: APIClient.httpBaseURL(from: endpoint.wsURL),
      authToken: endpoint.authToken
    )
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
    eventStream: EventStream,
    sessionStore: SessionStore? = nil
  ) {
    self.endpoint = endpoint
    self.apiClient = apiClient
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
    let endpointId = endpoint.id
    let apiClient = self.apiClient
    return ServerControlPlanePort(
      endpointId: endpointId,
      setServerRole: { isPrimary in
        try await apiClient.setServerRole(isPrimary: isPrimary)
      },
      setClientPrimaryClaim: { identity, isPrimary in
        try await apiClient.setClientPrimaryClaim(
          clientId: identity.clientId,
          deviceName: identity.deviceName,
          isPrimary: isPrimary
        )
      }
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
