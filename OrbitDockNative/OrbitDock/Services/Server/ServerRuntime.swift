import Foundation

@MainActor
final class ServerRuntime: Identifiable {
  let endpoint: ServerEndpoint
  let clients: ServerClients
  let controlPlaneClient: ControlPlaneClient
  let connection: ServerConnection
  let sessionStore: SessionStore
  var onServerMetaRefreshed: ((ServerMetaResponse) -> Void)?

  private(set) var isStarted = false

  init(endpoint: ServerEndpoint) {
    let connection = ServerConnection(authToken: endpoint.authToken)
    let baseURL = ServerURLResolver.httpBaseURL(from: endpoint.wsURL)
    let requestBuilder = HTTPRequestBuilder(baseURL: baseURL, authToken: endpoint.authToken)

    self.endpoint = endpoint
    self.connection = connection
    self.clients = ServerClients(
      baseURL: baseURL,
      requestBuilder: requestBuilder,
      responseLoader: { [weak connection] request in
        guard let connection else { throw HTTPTransportError.serverUnreachable }
        return try await connection.execute(request)
      }
    )
    self.controlPlaneClient = clients.controlPlane
    self.sessionStore = SessionStore(
      clients: clients,
      connection: connection,
      endpointId: endpoint.id,
      endpointName: endpoint.name
    )
  }

  init(
    endpoint: ServerEndpoint,
    clients: ServerClients,
    controlPlaneClient: ControlPlaneClient? = nil,
    connection: ServerConnection,
    sessionStore: SessionStore? = nil
  ) {
    self.endpoint = endpoint
    self.clients = clients
    self.controlPlaneClient = controlPlaneClient ?? clients.controlPlane
    self.connection = connection
    self.sessionStore = sessionStore
      ?? SessionStore(
        clients: clients,
        connection: connection,
        endpointId: endpoint.id,
        endpointName: endpoint.name
      )
  }

  var id: UUID {
    endpoint.id
  }

  var controlPlanePort: ServerControlPlanePort {
    ServerControlPlanePort(
      endpointId: endpoint.id,
      client: controlPlaneClient
    )
  }

  var readiness: ServerRuntimeReadiness {
    ServerRuntimeReadiness.derive(
      connectionStatus: connection.connectionStatus,
      hasReceivedInitialDashboardSnapshot: connection.hasReceivedInitialDashboardSnapshot,
      hasReceivedInitialMissionsSnapshot: connection.hasReceivedInitialMissionsSnapshot
    )
  }

  func start() {
    guard endpoint.isEnabled else { return }
    guard !isStarted else { return }
    sessionStore.startProcessingEvents()
    connection.connect(to: endpoint.wsURL)
    isStarted = true
    refreshServerIdentity()
  }

  func stop() {
    guard isStarted else { return }
    connection.disconnect()
    sessionStore.stopProcessingEvents()
    isStarted = false
  }

  func reconnect() {
    guard endpoint.isEnabled else { return }
    sessionStore.startProcessingEvents()
    if isStarted {
      connection.disconnect()
    }
    connection.connect(to: endpoint.wsURL)
    isStarted = true
    refreshServerIdentity()
  }

  func reconnectIfNeeded() {
    guard isStarted else { return }
    connection.reconnectIfNeeded()
  }

  func suspendInactive() {
    stop()
  }

  private func refreshServerIdentity() {
    Task {
      do {
        let meta = try await clients.updates.fetchServerMeta()
        let normalized = meta.serverInstanceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionStore.serverInstanceId = (normalized?.isEmpty == false) ? normalized : nil
        onServerMetaRefreshed?(meta)
      } catch {
        // Best-effort metadata fetch for server identity gating.
      }
    }
  }
}
