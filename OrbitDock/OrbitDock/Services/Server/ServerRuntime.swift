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

  var id: UUID {
    endpoint.id
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
