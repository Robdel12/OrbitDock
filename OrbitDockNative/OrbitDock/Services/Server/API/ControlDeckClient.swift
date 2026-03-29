import Foundation

struct ControlDeckClient: Sendable {
  struct SubmitTurnResponse: Decodable {
    let accepted: Bool
    let row: ServerConversationRowEntry
  }

  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func fetchSnapshot(_ sessionId: String) async throws -> ServerControlDeckSnapshotPayload {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/control-deck"
    )
  }

  func updateConfig(
    _ sessionId: String,
    request: ServerControlDeckConfigUpdateRequest
  ) async throws -> ServerControlDeckSnapshotPayload {
    try await http.request(
      path: "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/control-deck",
      method: "PATCH",
      body: request
    )
  }

  func fetchPreferences() async throws -> ServerControlDeckPreferences {
    try await http.get("/api/control-deck/preferences")
  }

  func updatePreferences(_ request: ServerControlDeckPreferences) async throws -> ServerControlDeckPreferences {
    try await http.request(
      path: "/api/control-deck/preferences",
      method: "PUT",
      body: request
    )
  }

  struct ImageAttachmentUploadResponse: Decodable {
    let attachment: ServerControlDeckImageAttachmentRef

    enum CodingKeys: String, CodingKey {
      case attachment
    }
  }

  func uploadImageAttachment(
    sessionId: String,
    data: Data,
    mimeType: String,
    displayName: String,
    pixelWidth: Int?,
    pixelHeight: Int?
  ) async throws -> ServerControlDeckImageAttachmentRef {
    var query = [URLQueryItem(name: "display_name", value: displayName)]
    if let pixelWidth {
      query.append(URLQueryItem(name: "pixel_width", value: "\(pixelWidth)"))
    }
    if let pixelHeight {
      query.append(URLQueryItem(name: "pixel_height", value: "\(pixelHeight)"))
    }

    let response: ImageAttachmentUploadResponse = try await http.requestRaw(
      path: "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/control-deck/attachments/images",
      method: "POST",
      bodyData: data,
      contentType: mimeType,
      query: query
    )
    return response.attachment
  }

  func submitTurn(
    _ sessionId: String,
    request: ServerControlDeckSubmitTurnRequest
  ) async throws -> SubmitTurnResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/control-deck/submit",
      body: request
    )
  }
}
