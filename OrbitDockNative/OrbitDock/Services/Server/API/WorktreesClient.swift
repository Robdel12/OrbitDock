import Foundation

struct WorktreesClient: Sendable {
  private let http: ServerHTTPClient
  private let requestBuilder: HTTPRequestBuilder

  init(http: ServerHTTPClient, requestBuilder: HTTPRequestBuilder) {
    self.http = http
    self.requestBuilder = requestBuilder
  }

  func listWorktrees(repoRoot: String) async throws -> [ServerWorktreeSummary] {
    struct Response: Decodable { let worktrees: [ServerWorktreeSummary] }
    let response: Response = try await http.get(
      "/api/worktrees",
      query: [URLQueryItem(name: "repo_root", value: repoRoot)]
    )
    return response.worktrees
  }

  func createWorktree(
    repoPath: String,
    branchName: String,
    baseBranch: String?
  ) async throws -> ServerWorktreeSummary {
    struct Body: Encodable {
      let repoPath: String
      let branchName: String
      let baseBranch: String?
    }
    struct Response: Decodable { let worktree: ServerWorktreeSummary }
    let response: Response = try await http.post(
      "/api/worktrees",
      body: Body(repoPath: repoPath, branchName: branchName, baseBranch: baseBranch)
    )
    return response.worktree
  }

  func removeWorktree(
    worktreeId: String,
    force: Bool = false,
    deleteBranch: Bool = false,
    deleteRemoteBranch: Bool = false,
    archiveOnly: Bool = false
  ) async throws {
    struct Response: Decodable { let ok: Bool }
    let _: Response = try await http.request(
      path: "/api/worktrees/\(requestBuilder.encodePathComponent(worktreeId))",
      method: "DELETE",
      query: [
        URLQueryItem(name: "force", value: force ? "true" : "false"),
        URLQueryItem(name: "delete_branch", value: deleteBranch ? "true" : "false"),
        URLQueryItem(name: "delete_remote_branch", value: deleteRemoteBranch ? "true" : "false"),
        URLQueryItem(name: "archive_only", value: archiveOnly ? "true" : "false"),
      ]
    )
  }

  func discoverWorktrees(repoPath: String) async throws -> [ServerWorktreeSummary] {
    struct Body: Encodable { let repoPath: String }
    struct Response: Decodable { let worktrees: [ServerWorktreeSummary] }
    let response: Response = try await http.post(
      "/api/worktrees/discover",
      body: Body(repoPath: repoPath)
    )
    return response.worktrees
  }

  func gitInit(path: String) async throws -> Bool {
    struct Body: Encodable { let path: String }
    struct Response: Decodable { let ok: Bool }
    let response: Response = try await http.post("/api/git/init", body: Body(path: path))
    return response.ok
  }
}
