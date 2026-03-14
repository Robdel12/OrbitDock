import Foundation

struct ConversationClient: Sendable {
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
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/conversation",
      query: [URLQueryItem(name: "limit", value: "\(limit)")]
    )
  }

  func fetchConversationHistory(
    _ sessionId: String,
    beforeSequence: UInt64,
    limit: Int = 100
  ) async throws -> ServerConversationHistoryPage {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/messages",
      query: [
        URLQueryItem(name: "limit", value: "\(limit)"),
        URLQueryItem(name: "before_sequence", value: "\(beforeSequence)"),
      ]
    )
  }

  func sendMessage(_ sessionId: String, request: SendMessageRequest) async throws {
    let _: ServerAcceptedResponse = try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/messages",
      body: request
    )
  }

  func steerTurn(_ sessionId: String, request: SteerTurnRequest) async throws {
    try await http.sendVoid(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/steer",
      method: "POST",
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
