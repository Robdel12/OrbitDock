import Foundation

@MainActor
final class WorktreeService {
  private let endpointStore: ServerEndpointRuntime

  init(endpointStore: ServerEndpointRuntime) {
    self.endpointStore = endpointStore
  }

  func listWorktrees(repoRoot: String) async throws -> [ServerWorktreeSummary] {
    let worktrees = try await endpointStore.clients.worktrees.listWorktrees(repoRoot: repoRoot)
    endpointStore.worktreesByRepo[repoRoot] = worktrees
    return worktrees
  }

  func discoverWorktrees(repoPath: String) async throws -> [ServerWorktreeSummary] {
    let worktrees = try await endpointStore.clients.worktrees.discoverWorktrees(repoPath: repoPath)
    endpointStore.worktreesByRepo[repoPath] = worktrees
    return worktrees
  }

  func createWorktree(
    repoPath: String,
    branchName: String,
    baseBranch: String?
  ) async throws -> ServerWorktreeSummary {
    try await endpointStore.clients.worktrees.createWorktree(
      repoPath: repoPath,
      branchName: branchName,
      baseBranch: baseBranch
    )
  }

  func removeWorktree(
    worktreeId: String,
    force: Bool = false,
    deleteBranch: Bool = false,
    deleteRemoteBranch: Bool = false,
    archiveOnly: Bool = false
  ) async throws {
    try await endpointStore.clients.worktrees.removeWorktree(
      worktreeId: worktreeId,
      force: force,
      deleteBranch: deleteBranch,
      deleteRemoteBranch: deleteRemoteBranch,
      archiveOnly: archiveOnly
    )
    removeWorktreeFromCache(worktreeId: worktreeId)
  }

  private func removeWorktreeFromCache(worktreeId: String) {
    let repoRoots = Array(endpointStore.worktreesByRepo.keys)
    for repoRoot in repoRoots {
      guard let worktrees = endpointStore.worktreesByRepo[repoRoot] else { continue }
      let updatedWorktrees = worktrees.filter { $0.id != worktreeId }
      if updatedWorktrees.count != worktrees.count {
        endpointStore.worktreesByRepo[repoRoot] = updatedWorktrees
      }
    }
  }
}
