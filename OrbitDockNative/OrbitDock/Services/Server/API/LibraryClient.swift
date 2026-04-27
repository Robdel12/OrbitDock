import Foundation

struct ArchivedSessionsClient: Sendable {
  let http: ServerHTTPClient

  func fetchSnapshot(
    limit: Int = 200,
    offset: Int = 0,
    query: String? = nil
  ) async throws -> ServerLibrarySnapshotPayload {
    var queryItems = [
      URLQueryItem(name: "limit", value: "\(max(limit, 1))"),
      URLQueryItem(name: "offset", value: "\(max(offset, 0))"),
    ]
    if let query, !query.isEmpty {
      queryItems.append(URLQueryItem(name: "q", value: query))
    }

    let snapshot: ServerLibrarySnapshotPayload = try await http.get(
      "/api/sessions/archive",
      query: queryItems
    )
    return snapshot
  }
}
