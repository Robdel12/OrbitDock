import Foundation

struct FeatureFlagsClient: Sendable {
  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func applyFlagSettings(sessionId: String, settings: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: settings)
    try await http.sendVoidRaw(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/flags",
      method: "POST",
      bodyData: data
    )
  }
}
