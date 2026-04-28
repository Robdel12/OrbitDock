import Foundation

@MainActor
final class ServerRuntime: Identifiable {
  let endpoint: ServerEndpoint
  let clients: ServerClients
  let sessionsSummaryClient: SessionsSummaryClient
  let serverRoleClient: ServerRoleClient
  let connection: ServerConnection
  let endpointStore: ServerEndpointRuntime
  let toolPtyManager: ToolPtySessionManager
  var onServerMetaRefreshed: ((ServerMetaResponse) -> Void)?

  private(set) var isStarted = false
  private var toolPtyListenerToken: ServerConnectionListenerToken?

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
    self.sessionsSummaryClient = clients.sessionsSummary
    self.serverRoleClient = clients.serverRole
    self.endpointStore = ServerEndpointRuntime(
      clients: clients,
      connection: connection,
      endpointId: endpoint.id,
      endpointName: endpoint.name
    )
    self.toolPtyManager = ToolPtySessionManager()
  }

  init(
    endpoint: ServerEndpoint,
    clients: ServerClients,
    sessionsSummaryClient: SessionsSummaryClient? = nil,
    serverRoleClient: ServerRoleClient? = nil,
    connection: ServerConnection,
    endpointStore: ServerEndpointRuntime? = nil,
    toolPtyManager: ToolPtySessionManager? = nil
  ) {
    self.endpoint = endpoint
    self.clients = clients
    self.sessionsSummaryClient = sessionsSummaryClient ?? clients.sessionsSummary
    self.serverRoleClient = serverRoleClient ?? clients.serverRole
    self.connection = connection
    self.endpointStore = endpointStore
      ?? ServerEndpointRuntime(
        clients: clients,
        connection: connection,
        endpointId: endpoint.id,
        endpointName: endpoint.name
      )
    self.toolPtyManager = toolPtyManager ?? ToolPtySessionManager()
  }

  var id: UUID {
    endpoint.id
  }

  var serverRolePort: ServerRolePort {
    ServerRolePort(
      endpointId: endpoint.id,
      client: serverRoleClient
    )
  }

  var readiness: ServerRuntimeReadiness {
    ServerRuntimeReadiness.derive(connectionStatus: connection.connectionStatus)
  }

  func start() {
    guard endpoint.isEnabled else { return }
    guard !isStarted else { return }
    endpointStore.startProcessingEvents()
    startToolPtyEventRouting()
    connection.connect(to: endpoint.wsURL)
    isStarted = true
    refreshServerIdentity()
  }

  func stop() {
    guard isStarted else { return }
    stopToolPtyEventRouting()
    connection.disconnect()
    endpointStore.stopProcessingEvents()
    isStarted = false
  }

  func reconnect() {
    guard endpoint.isEnabled else { return }
    endpointStore.startProcessingEvents()
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
    guard isStarted else { return }
    stopToolPtyEventRouting()
    connection.disconnect()
    endpointStore.suspendProcessingEventsForBackground()
    isStarted = false
  }

  private func refreshServerIdentity() {
    Task {
      do {
        let meta = try await clients.updates.fetchServerMeta()
        let normalized = meta.serverInstanceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        endpointStore.serverInstanceId = (normalized?.isEmpty == false) ? normalized : nil
        onServerMetaRefreshed?(meta)
      } catch {
        // Best-effort metadata fetch for server identity gating.
      }
    }
  }

  // MARK: - Tool PTY Event Routing

  private func startToolPtyEventRouting() {
    guard toolPtyListenerToken == nil else { return }

    toolPtyListenerToken = connection.addListener { [weak self] event in
      guard let self else { return }
      switch event {
      case let .toolPtyAttached(toolId, bufferedOutput):
        toolPtyManager.handleAttached(toolId: toolId, bufferedOutput: bufferedOutput)

      case let .toolPtyDetached(toolId):
        toolPtyManager.handleDetached(toolId: toolId)

      case let .toolPtyExited(toolId, exitCode):
        toolPtyManager.handleExited(toolId: toolId, exitCode: exitCode)

      case let .terminalOutput(terminalId, data):
        // Route binary output frames for tool PTY sessions while the client is
        // actively attached. Completed tools should fall back to transcript-backed
        // REST content instead of holding onto the capped PTY replay buffer.
        if toolPtyManager.isAttached(terminalId) {
          toolPtyManager.feedOutput(toolId: terminalId, data: data)
        }

      default:
        break
      }
    }
  }

  private func stopToolPtyEventRouting() {
    if let token = toolPtyListenerToken {
      connection.removeListener(token)
      toolPtyListenerToken = nil
    }
  }
}
