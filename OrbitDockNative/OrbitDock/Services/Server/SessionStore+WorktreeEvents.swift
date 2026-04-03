import Foundation

@MainActor
extension SessionStore {
  func routeWorktreeEvent(_ event: ServerEvent) -> Bool {
    switch event {
      case let .worktreesList(_, repoRoot, _, worktrees):
        handleWorktreesList(repoRoot: repoRoot, worktrees: worktrees)
        return true
      case let .worktreeCreated(_, _, _, worktree):
        handleWorktreeCreated(worktree: worktree)
        return true
      case let .worktreeRemoved(_, repoRoot, _, worktreeId):
        handleWorktreeRemoved(repoRoot: repoRoot, worktreeId: worktreeId)
        return true
      case let .worktreeStatusChanged(worktreeId, status, repoRoot):
        handleWorktreeStatusChanged(worktreeId: worktreeId, status: status, repoRoot: repoRoot)
        return true
      case .worktreeError(_, _, _):
        return true
      default:
        return false
    }
  }

  func handleWorktreesList(repoRoot: String?, worktrees: [ServerWorktreeSummary]) {
    guard let repoRoot else { return }
    worktreesByRepo[repoRoot] = worktrees
  }

  func handleWorktreeCreated(worktree: ServerWorktreeSummary) {
    worktreesByRepo[worktree.repoRoot, default: []].append(worktree)
  }

  func handleWorktreeRemoved(repoRoot: String, worktreeId: String) {
    worktreesByRepo[repoRoot]?.removeAll { $0.id == worktreeId }
  }

  func handleWorktreeStatusChanged(worktreeId: String, status: ServerWorktreeStatus, repoRoot: String) {
    if var worktrees = worktreesByRepo[repoRoot],
       let index = worktrees.firstIndex(where: { $0.id == worktreeId })
    {
      worktrees[index].status = status
      worktreesByRepo[repoRoot] = worktrees
    }
  }
}
