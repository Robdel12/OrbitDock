import Foundation
import Observation

struct WorktreeRemoveAttempt: Identifiable {
  let worktreeId: String
  let branch: String
  let worktreePath: String
  let force: Bool
  let deleteBranch: Bool
  let deleteRemoteBranch: Bool
  let archiveOnly: Bool

  var id: String {
    worktreeId
  }
}

enum WorktreeRemoveFeedbackAlert: Identifiable {
  case dirty(WorktreeRemoveAttempt)
  case error(String)

  var id: String {
    switch self {
      case let .dirty(attempt):
        "dirty-\(attempt.id)-\(attempt.force)-\(attempt.deleteBranch)-\(attempt.deleteRemoteBranch)"
      case let .error(message):
        "error-\(message)"
    }
  }
}

@MainActor
@Observable
final class WorktreeListViewModel {
  var worktrees: [ServerWorktreeSummary] = []
  var showCreateSheet = false
  var worktreeForCleanup: ServerWorktreeSummary?
  var cleanupSheetMode: WorktreeCleanupMode = .complete
  var lastRemoveAttempt: WorktreeRemoveAttempt?
  var removeFeedbackAlert: WorktreeRemoveFeedbackAlert?

  @ObservationIgnored private weak var serverState: SessionStore?
  @ObservationIgnored private var worktreeService: WorktreeService?
  @ObservationIgnored private var worktreeObservationGeneration: UInt64 = 0
  @ObservationIgnored private var repoRoot = ""

  func bind(serverState: SessionStore, repoRoot: String) {
    self.serverState = serverState
    worktreeService = WorktreeService(sessionStore: serverState)
    self.repoRoot = repoRoot
    worktreeObservationGeneration &+= 1
    startObservation(generation: worktreeObservationGeneration)
  }

  func refreshWorktrees() {
    guard let worktreeService else { return }
    Task {
      try? await worktreeService.listWorktrees(repoRoot: repoRoot)
    }
  }

  func discoverWorktrees() {
    guard let worktreeService else { return }
    Task {
      try? await worktreeService.discoverWorktrees(repoPath: repoRoot)
    }
  }

  func beginCreateWorktree() {
    showCreateSheet = true
  }

  func cancelCreateWorktree() {
    showCreateSheet = false
  }

  func createWorktree(branchName: String, baseBranch: String?) {
    guard let worktreeService else { return }

    let trimmedBranchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBaseBranch = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBranchName.isEmpty else { return }

    Platform.services.playHaptic(.action)
    showCreateSheet = false

    Task {
      try? await worktreeService.createWorktree(
        repoPath: repoRoot,
        branchName: trimmedBranchName,
        baseBranch: trimmedBaseBranch?.isEmpty == true ? nil : trimmedBaseBranch
      )
    }
  }

  func beginCleanup(for worktree: ServerWorktreeSummary, mode: WorktreeCleanupMode) {
    cleanupSheetMode = mode
    worktreeForCleanup = worktree
  }

  func cancelCleanup() {
    worktreeForCleanup = nil
  }

  func confirmCleanup(for worktree: ServerWorktreeSummary, request: WorktreeCleanupRequest) {
    let attempt = WorktreeRemoveAttempt(
      worktreeId: worktree.id,
      branch: worktree.branch,
      worktreePath: worktree.worktreePath,
      force: request.force,
      deleteBranch: request.deleteBranch,
      deleteRemoteBranch: request.deleteRemoteBranch,
      archiveOnly: request.archiveOnly
    )

    lastRemoveAttempt = attempt
    worktreeForCleanup = nil

    guard let worktreeService else { return }
    Task {
      try? await worktreeService.removeWorktree(
        worktreeId: worktree.id,
        force: request.force,
        deleteBranch: request.deleteBranch,
        deleteRemoteBranch: request.deleteRemoteBranch,
        archiveOnly: request.archiveOnly
      )
    }
  }

  func handleRemoveError(_ lastServerError: (code: String, message: String)?) {
    guard let attempt = lastRemoveAttempt else { return }
    guard let error = lastServerError else { return }
    guard error.code == "remove_failed" else { return }
    guard !attempt.archiveOnly else { return }

    serverState?.clearServerError()

    if !attempt.force, error.message.localizedCaseInsensitiveContains("contains modified or untracked files") {
      removeFeedbackAlert = .dirty(attempt)
      return
    }

    removeFeedbackAlert = .error(error.message)
  }

  func forceRemove(_ attempt: WorktreeRemoveAttempt) {
    guard let worktreeService else { return }

    let forceAttempt = WorktreeRemoveAttempt(
      worktreeId: attempt.worktreeId,
      branch: attempt.branch,
      worktreePath: attempt.worktreePath,
      force: true,
      deleteBranch: attempt.deleteBranch,
      deleteRemoteBranch: attempt.deleteRemoteBranch,
      archiveOnly: false
    )

    lastRemoveAttempt = forceAttempt

    Task {
      try? await worktreeService.removeWorktree(
        worktreeId: attempt.worktreeId,
        force: true,
        deleteBranch: attempt.deleteBranch,
        deleteRemoteBranch: attempt.deleteRemoteBranch,
        archiveOnly: false
      )
    }
  }

  private func startObservation(generation: UInt64) {
    guard let serverState else {
      worktrees = []
      return
    }

    let snapshot = withObservationTracking {
      Self.filteredWorktrees(serverState.worktrees(for: repoRoot))
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.worktreeObservationGeneration == generation else { return }
        self.startObservation(generation: generation)
      }
    }

    worktrees = snapshot
  }

  private static func filteredWorktrees(_ worktrees: [ServerWorktreeSummary]) -> [ServerWorktreeSummary] {
    worktrees
      .filter { $0.status != .removed }
      .sorted { $0.createdAt > $1.createdAt }
  }
}
