import SwiftUI

struct SessionDetailDiffAvailableBanner: View {
  let fileCount: Int
  let onRevealReview: () -> Void

  var body: some View {
    Button(action: onRevealReview) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "doc.badge.plus")
          .font(.system(size: TypeScale.body, weight: .medium))
        Text("\(fileCount) file\(fileCount == 1 ? "" : "s") changed — Review Diffs")
          .font(.system(size: TypeScale.body, weight: .medium))
        Image(systemName: "arrow.right")
          .font(.system(size: TypeScale.micro, weight: .bold))
      }
      .foregroundStyle(Color.accent)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(Color.accent.opacity(OpacityTier.subtle), in: Capsule())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundSecondary)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}
