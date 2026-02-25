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
}
