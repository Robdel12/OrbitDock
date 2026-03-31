import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerConnectionTransportTests {
  @Test func executeDoesNotRequireConnectedWebSocket() async throws {
    let transport = TransportSpy(
      response: HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"status":"ok"}"#.utf8)
      )
    )
    let connection = ServerConnection(authToken: nil, transport: transport)
    let request = try #require(URL(string: "http://127.0.0.1:4000/health"))

    let response = try await connection.execute(URLRequest(url: request))

    #expect(response.statusCode == 200)
    #expect(await transport.executeRequestCount() == 1)
    #expect(await transport.lastExecutedURL() == request)
  }

  @Test func acceptsLegacyServerInfoAsInitialHandshake() async throws {
    let transport = TransportSpy(
      response: HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"status":"ok"}"#.utf8)
      ),
      framesOnConnect: [
        .text(
          #"{"type":"server_info","is_primary":true,"client_primary_claims":[]}"#,
          expectedGeneration: 1
        )
      ]
    )
    let connection = ServerConnection(authToken: nil, transport: transport)
    let url = try #require(URL(string: "ws://127.0.0.1:4000/ws"))

    connection.connect(to: url)
    await drainMainActorTasks()

    #expect(connection.connectionStatus == .connected)
    #expect(connection.requiresManualReconnect == false)

    connection.disconnect()
  }

  @Test func readinessTracksDashboardAndMissionsIndependently() {
    let readiness = ServerRuntimeReadiness.derive(
      connectionStatus: .connected,
      hasReceivedInitialDashboardSnapshot: true,
      hasReceivedInitialMissionsSnapshot: false
    )

    #expect(readiness.transportReady)
    #expect(readiness.controlPlaneReady)
    #expect(readiness.dashboardReady)
    #expect(readiness.missionsReady == false)
  }

  @Test func readinessStaysUsableWithBootstrapWhenWebSocketDrops() {
    let readiness = ServerRuntimeReadiness.derive(
      connectionStatus: .disconnected,
      hasReceivedInitialDashboardSnapshot: true,
      hasReceivedInitialMissionsSnapshot: false
    )

    #expect(readiness.transportReady)
    #expect(readiness.controlPlaneReady)
    #expect(readiness.dashboardReady)
    #expect(readiness.missionsReady == false)
  }

  @Test func executeOmitsMinimumServerVersionHeader() async throws {
    let success = HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: Data(#"{"status":"ok"}"#.utf8)
    )
    let transport = TransportSpy(responses: [success])
    let connection = ServerConnection(authToken: nil, transport: transport)
    let url = try #require(URL(string: "https://example.com/api/dashboard"))

    let first = try await connection.execute(URLRequest(url: url))

    #expect(first.statusCode == 200)
    #expect(await transport.executeRequestCount() == 1)
    #expect(
      await transport.headerValue(
        for: "X-OrbitDock-Client-Compatibility",
        at: 0
      ) == "server_authoritative_session_v1"
    )
    #expect(
      await transport.headerValue(
        for: "X-OrbitDock-Minimum-Server-Version",
        at: 0
      ) == nil
    )
  }

  @Test func executeDoesNotCacheIncompatibleClientFailures() async throws {
    let incompatible = HTTPResponse(
      statusCode: 426,
      headers: ["Content-Type": "application/json"],
      body: Data(#"{"code":"incompatible_client","error":"Update OrbitDock to a compatible build."}"#.utf8)
    )
    let transport = TransportSpy(responses: [incompatible, incompatible])
    let connection = ServerConnection(authToken: nil, transport: transport)
    let url = try #require(URL(string: "https://example.com/api/dashboard"))

    let first = try await connection.execute(URLRequest(url: url))

    #expect(first.statusCode == 426)
    #expect(await transport.executeRequestCount() == 1)

    let second = try await connection.execute(URLRequest(url: url))
    #expect(second.statusCode == 426)
    #expect(await transport.executeRequestCount() == 2)
  }

  @Test func dnsResolutionFailureRequiresManualReconnect() async throws {
    let transport = TransportSpy(
      response: HTTPResponse(
        statusCode: 200,
        headers: [:],
        body: Data()
      ),
      disconnectOnConnect: EndpointTransport.DisconnectFailure(
        transportError: .unreachable(.cannotFindHost, "Host lookup failed"),
        urlErrorCode: .cannotFindHost
      )
    )
    let connection = ServerConnection(authToken: nil, transport: transport)
    let url = try #require(URL(string: "wss://does-not-resolve.invalid/ws"))

    connection.connect(to: url)
    await drainMainActorTasks()

    #expect(connection.requiresManualReconnect)
    #expect(await transport.connectRequestCount() == 1)

    connection.reconnectIfNeeded()
    await drainMainActorTasks()

    #expect(await transport.connectRequestCount() == 1)

    connection.disconnect()
    connection.connect(to: url)
    await drainMainActorTasks()

    #expect(await transport.connectRequestCount() == 2)
  }

  private func drainMainActorTasks(iterations: Int = 40) async {
    for _ in 0..<iterations {
      await Task.yield()
    }
  }
}

private actor TransportSpy: ServerConnectionTransport {
  private var queuedResponses: [HTTPResponse]
  private let disconnectOnConnect: EndpointTransport.DisconnectFailure?
  private let framesOnConnect: [Frame]
  private var executedRequests: [URLRequest] = []
  private var connectRequests: [URL] = []

  init(response: HTTPResponse, disconnectOnConnect: EndpointTransport.DisconnectFailure? = nil) {
    self.queuedResponses = [response]
    self.disconnectOnConnect = disconnectOnConnect
    self.framesOnConnect = []
  }

  init(responses: [HTTPResponse], disconnectOnConnect: EndpointTransport.DisconnectFailure? = nil) {
    self.queuedResponses = responses
    self.disconnectOnConnect = disconnectOnConnect
    self.framesOnConnect = []
  }

  init(
    response: HTTPResponse,
    disconnectOnConnect: EndpointTransport.DisconnectFailure? = nil,
    framesOnConnect: [Frame]
  ) {
    self.queuedResponses = [response]
    self.disconnectOnConnect = disconnectOnConnect
    self.framesOnConnect = framesOnConnect
  }

  enum Frame: Sendable {
    case text(String, expectedGeneration: UInt64)
  }

  func connect(
    to url: URL,
    generation: UInt64,
    onEvent: @escaping EndpointTransport.EventHandler
  ) async {
    connectRequests.append(url)
    for frame in framesOnConnect {
      switch frame {
        case let .text(text, expectedGeneration):
          if expectedGeneration == generation {
            await onEvent(.textFrame(text, generation: generation))
          }
      }
    }
    if let disconnectOnConnect {
      await onEvent(.disconnected(generation: generation, failure: disconnectOnConnect))
    }
  }

  func disconnect() async {}

  func activateKeepAlive(for generation: UInt64) async {}

  func probe(generation: UInt64) async throws {}

  func execute(_ request: URLRequest) async throws -> HTTPResponse {
    executedRequests.append(request)
    if queuedResponses.count > 1 {
      return queuedResponses.removeFirst()
    }
    if let response = queuedResponses.first {
      return response
    }
    return HTTPResponse(statusCode: 500, headers: [:], body: Data())
  }

  func sendText(_ text: String) async {}

  func executeRequestCount() -> Int {
    executedRequests.count
  }

  func lastExecutedURL() -> URL? {
    executedRequests.last?.url
  }

  func connectRequestCount() -> Int {
    connectRequests.count
  }

  func headerValue(for field: String, at index: Int) -> String? {
    guard executedRequests.indices.contains(index) else { return nil }
    return executedRequests[index].value(forHTTPHeaderField: field)
  }
}
