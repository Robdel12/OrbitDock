import Foundation

struct SessionControlsClient: Sendable {
  struct RollbackTurnsRequest: Encodable {
    let numTurns: UInt32

    enum CodingKeys: String, CodingKey {
      case numTurns = "num_turns"
    }
  }

  struct StopTargetRequest: Encodable {
    let targetId: String

    enum CodingKeys: String, CodingKey {
      case targetId = "target_id"
    }
  }

  struct RewindToMessageRequest: Encodable {
    let messageId: String

    enum CodingKeys: String, CodingKey {
      case messageId = "message_id"
    }
  }

  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func fetchSessionControls(_ sessionId: String) async throws -> ServerSessionControlsResponse {
    try await http.get(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/controls"
    )
  }

  func stopActiveTurn(_ sessionId: String) async throws -> ServerAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/controls/stop-active-turn",
      body: ServerEmptyBody()
    )
  }

  func compactContext(_ sessionId: String) async throws -> ServerAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/controls/compact-context",
      body: ServerEmptyBody()
    )
  }

  func undoLastTurn(_ sessionId: String) async throws -> ServerAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/controls/undo-last-turn",
      body: ServerEmptyBody()
    )
  }

  func rollbackTurns(_ sessionId: String, numTurns: UInt32) async throws -> ServerAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/controls/rollback-turns",
      body: RollbackTurnsRequest(numTurns: numTurns)
    )
  }

  func stopTarget(_ sessionId: String, targetId: String) async throws -> ServerAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/controls/stop-target",
      body: StopTargetRequest(targetId: targetId)
    )
  }

  func rewindToMessage(
    _ sessionId: String,
    messageId: String
  ) async throws -> ServerAcceptedResponse {
    try await http.post(
      "/api/sessions/\(requestBuilder.encodePathComponent(sessionId))/controls/rewind-to-message",
      body: RewindToMessageRequest(messageId: messageId)
    )
  }
}
