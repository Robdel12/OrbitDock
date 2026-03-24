import Foundation

struct ConversationClient: Sendable {
  struct SendMessageResponse: Decodable {
    let accepted: Bool
    let row: ServerConversationRowEntry
  }

  struct SteerTurnResponse: Decodable {
    let accepted: Bool
    let row: ServerConversationRowEntry
  }

  struct SendMessageRequest: Encodable {
    let content: String
    var model: String?
    var effort: String?
    var skills: [ServerSkillInput] = []
    var images: [ServerImageInput] = []
    var mentions: [ServerMentionInput] = []
  }

  struct SteerTurnRequest: Encodable {
    let content: String
    var images: [ServerImageInput] = []
    var mentions: [ServerMentionInput] = []
  }

  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func fetchConversationBootstrap(
    _ sessionId: String,
    limit: Int = 200
  ) async throws -> ServerConversationBootstrap {
    let path = "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation"
    let message = "GET \(path)?limit=\(limit) session=\(sessionId)"
    NSLog("[OrbitDock][ConversationClient] %@", message)
    return try await http.get(
      path,
      query: [URLQueryItem(name: "limit", value: "\(limit)")]
    )
  }

  func fetchConversationHistory(
    _ sessionId: String,
    beforeSequence: UInt64,
    limit: Int = 100
  ) async throws -> ServerConversationHistoryPage {
    let path = "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/messages"
    let message =
      "GET \(path)?limit=\(limit)&before_sequence=\(beforeSequence) session=\(sessionId)"
    NSLog("[OrbitDock][ConversationClient] %@", message)
    return try await http.get(
      path,
      query: [
        URLQueryItem(name: "limit", value: "\(limit)"),
        URLQueryItem(name: "before_sequence", value: "\(beforeSequence)"),
      ]
    )
  }

  func searchConversationRows(
    _ sessionId: String,
    query: ServerConversationSearchQuery
  ) async throws -> ServerConversationHistoryPage {
    var queryItems: [URLQueryItem] = []
    if let text = query.text, !text.isEmpty {
      queryItems.append(URLQueryItem(name: "q", value: text))
    }
    if let family = query.family {
      queryItems.append(URLQueryItem(name: "family", value: family.rawValue))
    }
    if let status = query.status {
      queryItems.append(URLQueryItem(name: "status", value: status.rawValue))
    }
    if let kind = query.kind {
      queryItems.append(URLQueryItem(name: "kind", value: kind.rawValue))
    }

    return try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/search",
      query: queryItems
    )
  }

  func fetchSessionStats(_ sessionId: String) async throws -> ServerSessionStats {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/stats"
    )
  }

  func fetchSessionInstructions(_ sessionId: String) async throws -> ServerSessionInstructions {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/instructions"
    )
  }

  func sendMessage(_ sessionId: String, request: SendMessageRequest) async throws -> SendMessageResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/messages",
      body: request
    )
  }

  func steerTurn(_ sessionId: String, request: SteerTurnRequest) async throws -> SteerTurnResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/steer",
      body: request
    )
  }

  func interruptSession(_ sessionId: String) async throws {
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/interrupt",
      body: ServerEmptyBody()
    )
  }

  func compactContext(_ sessionId: String) async throws {
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/compact",
      body: ServerEmptyBody()
    )
  }

  func undoLastTurn(_ sessionId: String) async throws {
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/undo",
      body: ServerEmptyBody()
    )
  }

  func rollbackTurns(_ sessionId: String, numTurns: UInt32) async throws {
    struct Body: Encodable { let numTurns: UInt32 }
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/rollback",
      body: Body(numTurns: numTurns)
    )
  }

  func stopTask(_ sessionId: String, taskId: String) async throws {
    struct Body: Encodable { let taskId: String }
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/stop-task",
      body: Body(taskId: taskId)
    )
  }

  func rewindFiles(_ sessionId: String, userMessageId: String) async throws {
    struct Body: Encodable { let userMessageId: String }
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/rewind-files",
      body: Body(userMessageId: userMessageId)
    )
  }

  func uploadImageAttachment(
    sessionId: String,
    data: Data,
    mimeType: String,
    displayName: String,
    pixelWidth: Int,
    pixelHeight: Int
  ) async throws -> ServerImageInput {
    let response: ServerUploadedImageAttachmentResponse = try await http.requestRaw(
      path: "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/attachments/images",
      method: "POST",
      bodyData: data,
      contentType: mimeType,
      query: [
        URLQueryItem(name: "display_name", value: displayName),
        URLQueryItem(name: "pixel_width", value: "\(pixelWidth)"),
        URLQueryItem(name: "pixel_height", value: "\(pixelHeight)"),
      ]
    )
    return response.image
  }

  func downloadImageAttachment(sessionId: String, attachmentId: String) async throws -> Data {
    try await http.fetchData(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/attachments/images/\(requestBuilder.encodePathComponent(attachmentId))"
    )
  }

  /// Fetch full expanded content for a tool row (input, output, diff).
  /// Content is computed on demand — not inlined in the row payload.
  func fetchRowContent(sessionId: String, rowId: String) async throws -> ServerRowContent {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/rows/\(requestBuilder.encodePathComponent(rowId))/content"
    )
  }

  func executeShell(sessionId: String, command: String, timeoutSecs: UInt64 = 120) async throws {
    struct Body: Encodable {
      let command: String
      let cwd: String?
      let timeoutSecs: UInt64

      enum CodingKeys: String, CodingKey {
        case command
        case cwd
        case timeoutSecs = "timeout_secs"
      }
    }
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/shell/exec",
      body: Body(command: command, cwd: nil, timeoutSecs: timeoutSecs)
    )
  }

  func cancelShell(sessionId: String, requestId: String) async throws {
    struct Body: Encodable { let requestId: String }
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/shell/cancel",
      body: Body(requestId: requestId)
    )
  }
}
