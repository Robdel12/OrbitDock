import Foundation
@testable import OrbitDock
import Testing

struct ServerRequestErrorTests {
  @Test func marksConnectorUnavailableConflicts() {
    let error = ServerRequestError.httpStatus(
      409,
      code: "session_not_found",
      message: "Session od-123 not found or has no active connector"
    )

    #expect(error.isConnectorUnavailableConflict)
  }

  @Test func doesNotMarkOtherHTTPFailuresAsConnectorUnavailable() {
    let error = ServerRequestError.httpStatus(
      409,
      code: "codex_action_error",
      message: "connector failed"
    )

    #expect(error.isConnectorUnavailableConflict == false)
  }

  @Test func nonHTTPFailuresDoNotLookLikeConnectorConflicts() {
    #expect(ServerRequestError.invalidResponse.isConnectorUnavailableConflict == false)
  }
}
