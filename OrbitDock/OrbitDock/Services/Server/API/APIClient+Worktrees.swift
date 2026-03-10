import Foundation

extension APIClient {

  func listWorktrees(repoRoot: String) async throws -> [ServerWorktreeSummary] {
    struct Resp: Decodable {
      let worktrees: [ServerWorktreeSummary]
    }
    let resp: Resp = try await get(
      "/api/worktrees",
      query: [URLQueryItem(name: "repo_root", value: repoRoot)])
    return resp.worktrees
  }

  func createWorktree(
    repoPath: String, branchName: String, baseBranch: String?
  ) async throws -> ServerWorktreeSummary {
    struct Body: Encodable {
      let repoPath: String
      let branchName: String
      let baseBranch: String?
    }
    struct Resp: Decodable { let worktree: ServerWorktreeSummary }
    let resp: Resp = try await post(
      "/api/worktrees",
      body: Body(repoPath: repoPath, branchName: branchName, baseBranch: baseBranch))
    return resp.worktree
  }

  func removeWorktree(
    worktreeId: String, force: Bool = false, deleteBranch: Bool = false,
    deleteRemoteBranch: Bool = false, archiveOnly: Bool = false
  ) async throws {
    struct Resp: Decodable { let ok: Bool }
    let _: Resp = try await request(
      path: "/api/worktrees/\(encode(worktreeId))", method: "DELETE",
      query: [
        URLQueryItem(name: "force", value: force ? "true" : "false"),
        URLQueryItem(name: "delete_branch", value: deleteBranch ? "true" : "false"),
        URLQueryItem(
          name: "delete_remote_branch", value: deleteRemoteBranch ? "true" : "false"),
        URLQueryItem(name: "archive_only", value: archiveOnly ? "true" : "false"),
      ])
  }

  func discoverWorktrees(repoPath: String) async throws -> [ServerWorktreeSummary] {
    struct Body: Encodable { let repoPath: String }
    struct Resp: Decodable { let worktrees: [ServerWorktreeSummary] }
    let resp: Resp = try await post(
      "/api/worktrees/discover", body: Body(repoPath: repoPath))
    return resp.worktrees
  }

  func gitInit(path: String) async throws -> Bool {
    struct Body: Encodable { let path: String }
    struct Resp: Decodable { let ok: Bool }
    let resp: Resp = try await post("/api/git/init", body: Body(path: path))
    return resp.ok
  }
}
