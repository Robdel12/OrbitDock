import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerClientsTests {

  @Test func convertsWebSocketURLsIntoHTTPBaseURLs() throws {
    let secure = try #require(URL(string: "wss://example.com/ws"))
    let insecure = try #require(URL(string: "ws://127.0.0.1:4000/ws"))
    let nested = try #require(URL(string: "wss://example.com/orbitdock/ws"))

    #expect(ServerURLResolver.httpBaseURL(from: secure).absoluteString == "https://example.com")
    #expect(ServerURLResolver.httpBaseURL(from: insecure).absoluteString == "http://127.0.0.1:4000")
    #expect(ServerURLResolver.httpBaseURL(from: nested).absoluteString == "https://example.com/orbitdock")
  }

  @Test func setServerRoleSendsScopedJSONAndAuthorizationHeader() async throws {
    let recorder = RequestRecorder()
    let clients = try ServerClients(
      serverURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      authToken: "secret-token",
      dataLoader: { request in
        await recorder.record(request)
        return Self.jsonResponse(
          url: request.url!,
          statusCode: 200,
          json: #"{"is_primary":true}"#
        )
      }
    )

    let isPrimary = try await clients.controlPlane.setServerRole(true)
    let request = try #require(await recorder.singleRequest())

    #expect(isPrimary)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/api/server/role")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["is_primary"] as? Bool == true)
  }

  @Test func setClientPrimaryClaimPostsExpectedBody() async throws {
    let recorder = RequestRecorder()
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: "secret-token",
      dataLoader: { request in
        await recorder.record(request)
        return Self.jsonResponse(
          url: request.url!,
          statusCode: 202,
          json: #"{"accepted":true}"#
        )
      }
    )

    try await clients.controlPlane.setClientPrimaryClaim(
      ServerClientIdentity(clientId: "client-1", deviceName: "Robert's MacBook Pro"),
      true
    )

    let request = try #require(await recorder.singleRequest())
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/client/primary-claim")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["client_id"] as? String == "client-1")
    #expect(payload["device_name"] as? String == "Robert's MacBook Pro")
    #expect(payload["is_primary"] as? Bool == true)
  }

  @Test func browseDirectoryPreservesPathQueryAndDecodesListing() async throws {
    let recorder = RequestRecorder()
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        await recorder.record(request)
        return Self.jsonResponse(
          url: request.url!,
          statusCode: 200,
          json: #"{"path":"/tmp/project","entries":[]}"#
        )
      }
    )

    let result = try await clients.filesystem.browseDirectory(path: "/tmp/project")
    let request = try #require(await recorder.singleRequest())
    let requestURL = try #require(request.url)
    let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))

    #expect(result.0 == "/tmp/project")
    #expect(result.1.isEmpty)
    #expect(components.path == "/api/fs/browse")
    #expect(components.queryItems?.contains(URLQueryItem(name: "path", value: "/tmp/project")) == true)
  }

  @Test func listSkillsRepeatsCwdQueryItemsAndForceReloadFlag() async throws {
    let recorder = RequestRecorder()
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        await recorder.record(request)
        return Self.jsonResponse(
          url: request.url!,
          statusCode: 200,
          json: #"{"session_id":"session-1","skills":[],"errors":[]}"#
        )
      }
    )

    let response = try await clients.skills.listSkills(
      sessionId: "session-1",
      cwds: ["/repo/a", "/repo/b"],
      forceReload: true
    )
    let request = try #require(await recorder.singleRequest())
    let requestURL = try #require(request.url)
    let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
    let cwdValues = components.queryItems?
      .filter { $0.name == "cwd" }
      .compactMap(\.value) ?? []

    #expect(response.sessionId == "session-1")
    #expect(response.skills.isEmpty)
    #expect(response.errors.isEmpty)
    #expect(cwdValues == ["/repo/a", "/repo/b"])
    #expect(components.queryItems?.contains(URLQueryItem(name: "force_reload", value: "true")) == true)
  }

  @Test func surfacesStructuredHTTPFailures() async throws {
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        Self.jsonResponse(
          url: request.url!,
          statusCode: 409,
          json: #"{"code":"session_not_found","error":"connector missing"}"#
        )
      }
    )

    do {
      _ = try await clients.sessions.fetchSessionSnapshot("missing-session")
      Issue.record("Expected fetchSessionSnapshot to surface the server error.")
    } catch let error as ServerRequestError {
      guard case let .httpStatus(status, code, message) = error else {
        Issue.record("Expected an HTTP status error.")
        return
      }
      #expect(status == 409)
      #expect(code == "session_not_found")
      #expect(message == "connector missing")
    } catch {
      Issue.record("Expected ServerRequestError, got \(error).")
    }
  }

  private nonisolated static func jsonResponse(
    url: URL,
    statusCode: Int,
    json: String
  ) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(json.utf8), response)
  }
}

private actor RequestRecorder {
  private var requests: [URLRequest] = []

  func record(_ request: URLRequest) {
    requests.append(request)
  }

  func singleRequest() -> URLRequest? {
    requests.last
  }
}
