import SwiftUI

struct SessionDetailWorktreeCleanupBanner: View {
  let bannerState: SessionDetailWorktreeCleanupBannerState?
  let errorMessage: String?
  @Binding var deleteBranchOnCleanup: Bool
  let isCleaningUp: Bool
  let onKeep: () -> Void
  let onCleanUp: () -> Void

  var body: some View {
    VStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.accent)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Worktree: \(bannerState?.branchName ?? "unknown")")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
          Text("This session used a worktree that may still be on disk.")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textSecondary)
        }
        Spacer()
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.statusPermission)
      }

      HStack(spacing: Spacing.md) {
        Toggle("Delete branch too", isOn: $deleteBranchOnCleanup)
        #if os(macOS)
          .toggleStyle(.checkbox)
        #endif
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textSecondary)

        Spacer()

        Button("Keep", action: onKeep)
          .buttonStyle(.plain)
          .foregroundStyle(Color.textSecondary)
          .font(.system(size: TypeScale.body, weight: .medium))

        Button(action: onCleanUp) {
          if isCleaningUp {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Clean Up")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)
        .font(.system(size: TypeScale.body, weight: .medium))
        .disabled(!(bannerState?.canCleanUp ?? false))
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundSecondary)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}
