@testable import OrbitDock
import Testing

struct WorktreeTogglePlannerTests {
  @Test
  func allowsEnablingWorktreesInsideGitRepositories() {
    let transition = WorktreeTogglePlanner.transition(
      requestedValue: true,
      selectedPathIsGit: true
    )

    #expect(
      transition == WorktreeToggleTransition(
        useWorktree: true,
        shouldClearError: true,
        shouldShowGitInitConfirmation: false
      )
    )
  }

  @Test
  func blocksEnablingWorktreesOutsideGitRepositories() {
    let transition = WorktreeTogglePlanner.transition(
      requestedValue: true,
      selectedPathIsGit: false
    )

    #expect(
      transition == WorktreeToggleTransition(
        useWorktree: false,
        shouldClearError: true,
        shouldShowGitInitConfirmation: true
      )
    )
  }

  @Test
  func allowsDisablingWorktreesWithoutShowingConfirmation() {
    let transition = WorktreeTogglePlanner.transition(
      requestedValue: false,
      selectedPathIsGit: false
    )

    #expect(
      transition == WorktreeToggleTransition(
        useWorktree: false,
        shouldClearError: true,
        shouldShowGitInitConfirmation: false
      )
    )
  }
}
