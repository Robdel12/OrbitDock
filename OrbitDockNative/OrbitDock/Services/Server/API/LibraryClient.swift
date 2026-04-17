import Foundation

struct ArchivedSessionsClient: Sendable {
  let http: ServerHTTPClient

  func fetchSnapshot(
    limit: Int = 200,
    offset: Int = 0
  ) async throws -> ServerLibrarySnapshotPayload {
    try await http.get(
      "/api/sessions/archive",
      query: [
        URLQueryItem(name: "limit", value: "\(max(limit, 1))"),
        URLQueryItem(name: "offset", value: "\(max(offset, 0))"),
      ]
    )
  }
}
