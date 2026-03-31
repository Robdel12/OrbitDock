import Foundation
@testable import OrbitDock
import Testing

struct HTTPRequestBuilderTests {
  @Test func buildsAuthenticatedJSONRequestWithNormalizedPathAndQuery() throws {
    let builder = try HTTPRequestBuilder(
      baseURL: #require(URL(string: "http://127.0.0.1:4000")),
      authToken: "secret-token"
    )

    let body = Data(#"{"hello":"world"}"#.utf8)
    let request = try builder.build(
      path: "api/test",
      method: "POST",
      query: [URLQueryItem(name: "page", value: "1")],
      contentType: "application/json",
      body: body
    )

    #expect(request.url?.absoluteString == "http://127.0.0.1:4000/api/test?page=1")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(
      request.value(forHTTPHeaderField: "X-OrbitDock-Client-Version")
        == "0.4.0"
    )
    #expect(
      request.value(forHTTPHeaderField: "X-OrbitDock-Client-Compatibility")
        == "server_authoritative_session_v1"
    )
    #expect(request.value(forHTTPHeaderField: "X-OrbitDock-Minimum-Server-Version") == nil)
    #expect(request.httpBody == body)
  }

  @Test func encodesPathComponentsForSessionRoutes() throws {
    let builder = try HTTPRequestBuilder(
      baseURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil
    )

    #expect(builder.encodePathComponent("session 1") == "session%201")
  }
}
