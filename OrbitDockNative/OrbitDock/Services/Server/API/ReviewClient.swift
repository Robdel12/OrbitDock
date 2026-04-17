import Foundation

struct ReviewClient: Sendable {
  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func fetchSnapshot(_ sessionId: String) async throws -> ServerSessionReviewSnapshotPayload {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/review"
    )
  }
}
