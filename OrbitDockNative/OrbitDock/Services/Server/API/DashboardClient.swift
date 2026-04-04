import Foundation

struct DashboardClient: Sendable {
  let http: ServerHTTPClient

  func fetchDashboardSnapshot() async throws -> ServerDashboardSnapshotPayload {
    try await http.get("/api/dashboard")
  }

  func fetchLibrarySnapshot(
    limit: Int = 200,
    offset: Int = 0
  ) async throws -> ServerLibrarySnapshotPayload {
    try await http.get(
      "/api/library",
      query: [
        URLQueryItem(name: "limit", value: "\(max(limit, 1))"),
        URLQueryItem(name: "offset", value: "\(max(offset, 0))"),
      ]
    )
  }
}
