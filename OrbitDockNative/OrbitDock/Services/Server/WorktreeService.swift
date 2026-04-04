import Foundation

@MainActor
final class WorktreeService {
  private let sessionStore: SessionStore

  init(sessionStore: SessionStore) {
    self.sessionStore = sessionStore
  }

  func listWorktrees(repoRoot: String) async throws -> [ServerWorktreeSummary] {
    let worktrees = try await sessionStore.clients.worktrees.listWorktrees(repoRoot: repoRoot)
    sessionStore.worktreesByRepo[repoRoot] = worktrees
    return worktrees
  }

  func discoverWorktrees(repoPath: String) async throws -> [ServerWorktreeSummary] {
    let worktrees = try await sessionStore.clients.worktrees.discoverWorktrees(repoPath: repoPath)
    sessionStore.worktreesByRepo[repoPath] = worktrees
    return worktrees
  }

  func createWorktree(
    repoPath: String,
    branchName: String,
    baseBranch: String?
  ) async throws -> ServerWorktreeSummary {
    try await sessionStore.clients.worktrees.createWorktree(
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
    try await sessionStore.clients.worktrees.removeWorktree(
      worktreeId: worktreeId,
      force: force,
      deleteBranch: deleteBranch,
      deleteRemoteBranch: deleteRemoteBranch,
      archiveOnly: archiveOnly
    )
    removeWorktreeFromCache(worktreeId: worktreeId)
  }

  func refreshWorktreesForActiveSessions() {
    // TODO: Pass repo roots from the calling view model instead of reading from a shared object
    let roots = Set<String>()
    for repoRoot in roots {
      Task {
        do {
          _ = try await listWorktrees(repoRoot: repoRoot)
        } catch {
          netLog(
            .error,
            cat: .store,
            "List worktrees failed",
            data: ["repoRoot": repoRoot, "error": error.localizedDescription]
          )
        }
      }
    }
  }

  private func removeWorktreeFromCache(worktreeId: String) {
    let repoRoots = Array(sessionStore.worktreesByRepo.keys)
    for repoRoot in repoRoots {
      guard let worktrees = sessionStore.worktreesByRepo[repoRoot] else { continue }
      let updatedWorktrees = worktrees.filter { $0.id != worktreeId }
      if updatedWorktrees.count != worktrees.count {
        sessionStore.worktreesByRepo[repoRoot] = updatedWorktrees
      }
    }
  }
}
