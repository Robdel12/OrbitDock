import Foundation

struct FilesystemClient: Sendable {
  private let http: ServerHTTPClient

  init(http: ServerHTTPClient) {
    self.http = http
  }

  func listRecentProjects() async throws -> [ServerRecentProject] {
    struct Response: Decodable { let projects: [ServerRecentProject] }
    let response: Response = try await http.get("/api/fs/recent-projects")
    return response.projects
  }

  func browseDirectory(path: String) async throws -> (String, [ServerDirectoryEntry]) {
    struct Response: Decodable {
      let path: String
      let entries: [ServerDirectoryEntry]
    }
    let response: Response = try await http.get(
      "/api/fs/browse",
      query: [URLQueryItem(name: "path", value: path)]
    )
    return (response.path, response.entries)
  }
}
