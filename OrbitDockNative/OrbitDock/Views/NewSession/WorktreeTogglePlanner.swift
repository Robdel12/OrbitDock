import Foundation

struct WorktreeToggleTransition: Equatable {
  let useWorktree: Bool
  let shouldClearError: Bool
  let shouldShowGitInitConfirmation: Bool
}

enum WorktreeTogglePlanner {
  static func transition(
    requestedValue: Bool,
    selectedPathIsGit: Bool
  ) -> WorktreeToggleTransition {
    if requestedValue, !selectedPathIsGit {
      return WorktreeToggleTransition(
        useWorktree: false,
        shouldClearError: true,
        shouldShowGitInitConfirmation: true
      )
    }

    return WorktreeToggleTransition(
      useWorktree: requestedValue,
      shouldClearError: true,
      shouldShowGitInitConfirmation: false
    )
  }
}
