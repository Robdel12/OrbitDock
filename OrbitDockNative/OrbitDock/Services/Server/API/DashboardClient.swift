import Foundation

struct ActiveSessionsClient: Sendable {
  let http: ServerHTTPClient

  func fetchSnapshot() async throws -> ServerDashboardSnapshotPayload {
    try await http.get("/api/sessions/active")
  }
}
