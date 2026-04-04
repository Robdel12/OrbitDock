import SwiftUI

struct NewSessionOptionsPanel<ConfigContent: View, ToolRestrictionsContent: View>: View {
  let provider: SessionProvider
  let hasSelectedPath: Bool

  @Binding var useWorktree: Bool
  @Binding var worktreeBranch: String
  @Binding var worktreeBaseBranch: String
  @Binding var worktreeError: String?
  let selectedPath: String
  let selectedPathIsGit: Bool
  let onGitInit: () -> Void

  @ViewBuilder let configurationContent: () -> ConfigContent
  @ViewBuilder let toolRestrictionsContent: () -> ToolRestrictionsContent

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      configurationContent()

      if hasSelectedPath {
        WorktreeFormSection(
          useWorktree: $useWorktree,
          worktreeBranch: $worktreeBranch,
          worktreeBaseBranch: $worktreeBaseBranch,
          worktreeError: $worktreeError,
          selectedPath: selectedPath,
          selectedPathIsGit: selectedPathIsGit,
          style: .embedded,
          onGitInit: onGitInit
        )
      }

      if provider == .claude {
        toolRestrictionsContent()
      }
    }
  }
}
