import Foundation

extension APIClient {

  func fetchConversationBootstrap(
    _ sessionId: String, limit: Int = 200
  ) async throws -> ServerConversationBootstrap {
    try await get(
      "/api/sessions/\(encode(sessionId))/conversation",
      query: [URLQueryItem(name: "limit", value: "\(limit)")]
    )
  }

  func fetchConversationHistory(
    _ sessionId: String, beforeSequence: UInt64, limit: Int = 100
  ) async throws -> ServerConversationHistoryPage {
    try await get(
      "/api/sessions/\(encode(sessionId))/messages",
      query: [
        URLQueryItem(name: "limit", value: "\(limit)"),
        URLQueryItem(name: "before_sequence", value: "\(beforeSequence)"),
      ]
    )
  }

  struct SendMessageRequest: Encodable {
    let content: String
    var model: String?
    var effort: String?
    var skills: [ServerSkillInput] = []
    var images: [ServerImageInput] = []
    var mentions: [ServerMentionInput] = []
  }

  func sendMessage(_ sessionId: String, request: SendMessageRequest) async throws {
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/messages", method: "POST",
      body: request)
  }

  struct SteerTurnRequest: Encodable {
    let content: String
    var images: [ServerImageInput] = []
    var mentions: [ServerMentionInput] = []
  }

  func steerTurn(_ sessionId: String, request: SteerTurnRequest) async throws {
    try await fireAndForget(
      "/api/sessions/\(encode(sessionId))/steer", method: "POST",
      body: request)
  }

  func interruptSession(_ sessionId: String) async throws {
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/interrupt", body: EmptyBody())
  }

  func compactContext(_ sessionId: String) async throws {
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/compact", body: EmptyBody())
  }

  func undoLastTurn(_ sessionId: String) async throws {
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/undo", body: EmptyBody())
  }

  func rollbackTurns(_ sessionId: String, numTurns: UInt32) async throws {
    struct Body: Encodable { let numTurns: UInt32 }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/rollback",
      body: Body(numTurns: numTurns))
  }

  func stopTask(_ sessionId: String, taskId: String) async throws {
    struct Body: Encodable { let taskId: String }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/stop-task",
      body: Body(taskId: taskId))
  }

  func rewindFiles(_ sessionId: String, userMessageId: String) async throws {
    struct Body: Encodable { let userMessageId: String }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/rewind-files",
      body: Body(userMessageId: userMessageId))
  }

  func uploadImageAttachment(
    sessionId: String, data: Data, mimeType: String,
    displayName: String, pixelWidth: Int, pixelHeight: Int
  ) async throws -> ServerImageInput {
    let resp: UploadedImageAttachmentResponse = try await requestRaw(
      path: "/api/sessions/\(encode(sessionId))/attachments/images",
      method: "POST",
      bodyData: data,
      contentType: mimeType,
      query: [
        URLQueryItem(name: "display_name", value: displayName),
        URLQueryItem(name: "pixel_width", value: "\(pixelWidth)"),
        URLQueryItem(name: "pixel_height", value: "\(pixelHeight)"),
      ]
    )
    return resp.image
  }

  func downloadImageAttachment(
    sessionId: String, attachmentId: String
  ) async throws -> Data {
    try await fetchData(
      "/api/sessions/\(encode(sessionId))/attachments/images/\(encode(attachmentId))")
  }

  func executeShell(
    sessionId: String, command: String, timeoutSecs: UInt64 = 120
  ) async throws {
    struct Body: Encodable { let command: String; let timeoutSecs: UInt64 }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/shell/exec",
      body: Body(command: command, timeoutSecs: timeoutSecs))
  }

  func cancelShell(sessionId: String, requestId: String) async throws {
    struct Body: Encodable { let requestId: String }
    let _: AcceptedResponse = try await post(
      "/api/sessions/\(encode(sessionId))/shell/cancel",
      body: Body(requestId: requestId))
  }
}
