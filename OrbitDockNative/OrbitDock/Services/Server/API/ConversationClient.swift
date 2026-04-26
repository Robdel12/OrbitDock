import Foundation

struct ConversationClient: Sendable {
  struct CommandAcceptedResponse: Decodable {
    let accepted: Bool
    let sessionDetailSnapshot: ServerSessionDetailSnapshotPayload?

    enum CodingKeys: String, CodingKey {
      case accepted
      case sessionDetailSnapshot = "session_detail_snapshot"
    }
  }

  struct SendMessageResponse: Decodable {
    let accepted: Bool
    let row: ServerConversationRowEntry
    let sessionDetailSnapshot: ServerSessionDetailSnapshotPayload?

    enum CodingKeys: String, CodingKey {
      case accepted
      case row
      case sessionDetailSnapshot = "session_detail_snapshot"
    }
  }

  struct SteerTurnResponse: Decodable {
    let accepted: Bool
    let row: ServerConversationRowEntry
    let sessionDetailSnapshot: ServerSessionDetailSnapshotPayload?

    enum CodingKeys: String, CodingKey {
      case accepted
      case row
      case sessionDetailSnapshot = "session_detail_snapshot"
    }
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

  struct SessionShellCommandRequest: Encodable {
    let command: String
  }

  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func fetchSessionDetail(_ sessionId: String) async throws -> ServerSessionDetailSnapshotPayload {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/detail"
    )
  }

  func fetchConversationBootstrap(
    _ sessionId: String,
    limit: Int = 200,
    source: String? = nil
  ) async throws -> ServerConversationBootstrap {
    let path = "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation"
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
    let path = "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/messages"
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
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/search",
      query: queryItems
    )
  }

  func fetchSessionStats(_ sessionId: String) async throws -> ServerSessionStats {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/stats"
    )
  }

  func fetchSessionInstructions(_ sessionId: String) async throws -> ServerSessionInstructions {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/instructions"
    )
  }

  func sendMessage(_ sessionId: String, request: SendMessageRequest) async throws -> SendMessageResponse {
    let path = "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/messages"
    return try await http.post(path, body: request)
  }

  func steerTurn(_ sessionId: String, request: SteerTurnRequest) async throws -> SteerTurnResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/steer",
      body: request
    )
  }

  func runSessionShellCommand(
    _ sessionId: String,
    command: String
  ) async throws -> ServerAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/shell-command",
      body: SessionShellCommandRequest(command: command)
    )
  }

  func interruptSession(_ sessionId: String) async throws -> CommandAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/interrupt",
      body: ServerEmptyBody()
    )
  }

  func compactContext(_ sessionId: String) async throws -> CommandAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/compact",
      body: ServerEmptyBody()
    )
  }

  func undoLastTurn(_ sessionId: String) async throws -> CommandAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/undo",
      body: ServerEmptyBody()
    )
  }

  func rollbackTurns(_ sessionId: String, numTurns: UInt32) async throws -> CommandAcceptedResponse {
    struct Body: Encodable { let numTurns: UInt32 }
    return try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/rollback",
      body: Body(numTurns: numTurns)
    )
  }

  func stopTask(_ sessionId: String, taskId: String) async throws -> CommandAcceptedResponse {
    struct Body: Encodable { let taskId: String }
    return try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/stop",
      body: Body(taskId: taskId)
    )
  }

  func rewindFiles(_ sessionId: String, userMessageId: String) async throws -> CommandAcceptedResponse {
    struct Body: Encodable { let userMessageId: String }
    return try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/rewind",
      body: Body(userMessageId: userMessageId)
    )
  }

  func uploadImageAttachment(
    sessionId: String,
    data: Data,
    mimeType: String,
    displayName: String,
    pixelWidth: Int?,
    pixelHeight: Int?
  ) async throws -> ServerImageInput {
    var query = [URLQueryItem(name: "display_name", value: displayName)]
    if let pixelWidth {
      query.append(URLQueryItem(name: "pixel_width", value: "\(pixelWidth)"))
    }
    if let pixelHeight {
      query.append(URLQueryItem(name: "pixel_height", value: "\(pixelHeight)"))
    }

    let response: ServerUploadedImageAttachmentResponse = try await http.requestRaw(
      path: "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/attachments/images",
      method: "POST",
      bodyData: data,
      contentType: mimeType,
      query: query
    )
    return response.image
  }

  func downloadImageAttachment(sessionId: String, attachmentId: String) async throws -> Data {
    try await http.fetchData(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/attachments/images/\(requestBuilder.encodePathComponent(attachmentId))"
    )
  }

  /// Fetch full expanded content for a tool row (input, output, diff).
  /// Content is computed on demand — not inlined in the row payload.
  func fetchRowContent(sessionId: String, rowId: String) async throws -> ServerRowContent {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/rows/\(requestBuilder.encodePathComponent(rowId))/content"
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
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/shell/exec",
      body: Body(command: command, cwd: nil, timeoutSecs: timeoutSecs)
    )
  }

  func cancelShell(sessionId: String, requestId: String) async throws {
    struct Body: Encodable { let requestId: String }
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation/shell/cancel",
      body: Body(requestId: requestId)
    )
  }
}
