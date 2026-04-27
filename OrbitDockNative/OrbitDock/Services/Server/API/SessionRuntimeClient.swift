import Foundation

struct SessionRuntimeClient: Sendable {
  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func fetchSessionInstructions(_ sessionId: String) async throws -> ServerSessionInstructions {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/instructions"
    )
  }

  func listCollaborationModes(
    _ sessionId: String
  ) async throws -> ServerSessionCollaborationModesResponse {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/collaboration-modes"
    )
  }
}
