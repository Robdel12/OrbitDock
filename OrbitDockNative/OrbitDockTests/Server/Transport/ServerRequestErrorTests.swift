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

  @Test func identifiesOnlyExplicitIncompatibleClientUpgradeFailures() {
    #expect(
      ServerRequestError.httpStatus(
        426,
        code: "incompatible_client",
        message: "Update OrbitDock to a compatible build."
      ).isIncompatibleClientUpgradeRequired
    )
    #expect(
      ServerRequestError.httpStatus(
        426,
        code: "something_else",
        message: "Update OrbitDock to a compatible build."
      ).isIncompatibleClientUpgradeRequired == false
    )
    #expect(
      ServerRequestError.httpStatus(
        401,
        code: "unauthorized",
        message: "Token expired."
      ).isIncompatibleClientUpgradeRequired == false
    )
    #expect(ServerRequestError.invalidResponse.isIncompatibleClientUpgradeRequired == false)
  }
}
