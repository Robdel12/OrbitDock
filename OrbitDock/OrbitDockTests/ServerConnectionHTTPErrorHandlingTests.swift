import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerConnectionHTTPErrorHandlingTests {
  @Test func suppressesConnectorUnavailableConflict() {
    let error = ServerRequestError.httpStatus(
      409,
      code: "session_not_found",
      message: "Session od-123 not found or has no active connector"
    )

    #expect(ServerConnection.shouldSuppressConnectorUnavailableError(error))
  }

  @Test func doesNotSuppressOtherConflicts() {
    let error = ServerRequestError.httpStatus(
      409,
      code: "codex_action_error",
      message: "connector failed"
    )

    #expect(!ServerConnection.shouldSuppressConnectorUnavailableError(error))
  }

  @Test func doesNotSuppressNonHttpErrors() {
    #expect(!ServerConnection.shouldSuppressConnectorUnavailableError(ServerRequestError.invalidResponse))
  }

  @Test func sendMessageQueuesWhileDisconnected() {
    let endpoint = makeEndpoint()
    let connection = ServerConnection(endpoint: endpoint)

    let result = connection.sendMessage(
      sessionId: "session-queued",
      content: "hello from queue"
    )

    #expect(result == .queued)
    #expect(connection.queuedConversationMessageCount == 1)
  }

  @Test func nonQueueableMessagesDropWhileDisconnected() {
    let endpoint = makeEndpoint()
    let connection = ServerConnection(endpoint: endpoint)

    let result = connection.send(.subscribeList)

    #expect(result == .dropped)
    #expect(connection.queuedConversationMessageCount == 0)
  }

  @Test func queuedMessagesRestoreForSameEndpointId() {
    let endpointId = UUID()
    let defaultsKey = "orbitdock.queued-conversation-messages.\(endpointId.uuidString)"
    UserDefaults.standard.removeObject(forKey: defaultsKey)
    defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

    let firstConnection = ServerConnection(endpoint: makeEndpoint(id: endpointId))
    let queued = firstConnection.sendMessage(
      sessionId: "session-restore",
      content: "persist me"
    )
    #expect(queued == .queued)
    #expect(firstConnection.queuedConversationMessageCount == 1)

    let restoredConnection = ServerConnection(endpoint: makeEndpoint(id: endpointId))
    #expect(restoredConnection.queuedConversationMessageCount == 1)
  }

  private func makeEndpoint(id: UUID = UUID()) -> ServerEndpoint {
    ServerEndpoint(
      id: id,
      name: "Test Endpoint",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
  }
}
