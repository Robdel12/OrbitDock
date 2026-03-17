import SwiftUI

struct MissionEmptyState: View {
  let icon: String
  let title: String
  let subtitle: String
  var iconColor: Color = .textQuaternary

  var body: some View {
    VStack(spacing: Spacing.lg) {
      ZStack {
        Circle()
          .strokeBorder(iconColor.opacity(OpacityTier.subtle), lineWidth: 2)
          .frame(width: 64, height: 64)

        Circle()
          .strokeBorder(iconColor.opacity(OpacityTier.medium), lineWidth: 1.5)
          .frame(width: 40, height: 40)

        Image(systemName: icon)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(iconColor)
      }

      VStack(spacing: Spacing.sm_) {
        Text(title)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textSecondary)

        Text(subtitle)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.xxl)
  }
}
