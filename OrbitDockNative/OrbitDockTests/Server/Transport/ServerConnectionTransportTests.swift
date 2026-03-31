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
}

private actor TransportSpy: ServerConnectionTransport {
  private let response: HTTPResponse
  private var executedRequests: [URLRequest] = []

  init(response: HTTPResponse) {
    self.response = response
  }

  func connect(
    to url: URL,
    clientVersion: String,
    minimumServerVersion: String,
    generation: UInt64,
    onEvent: @escaping EndpointTransport.EventHandler
  ) async {}

  func disconnect() async {}

  func activateKeepAlive(for generation: UInt64) async {}

  func probe(generation: UInt64) async throws {}

  func execute(_ request: URLRequest) async throws -> HTTPResponse {
    executedRequests.append(request)
    return response
  }

  func sendText(_ text: String) async {}

  func executeRequestCount() -> Int {
    executedRequests.count
  }

  func lastExecutedURL() -> URL? {
    executedRequests.last?.url
  }
}
