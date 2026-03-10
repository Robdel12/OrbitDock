import SwiftUI

struct SettingsSidebarButton: View {
  let title: String
  let subtitle: String
  let icon: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.md_) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(isSelected ? Color.accent : Color.textTertiary)
          .frame(width: 18)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(title)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(subtitle)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, Spacing.lg_)
      .padding(.vertical, Spacing.md_)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(isSelected ? Color.surfaceSelected : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(isSelected ? Color.surfaceBorder : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}

struct SettingsSection<Content: View>: View {
  let title: String
  let icon: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.meta, weight: .semibold))
          .foregroundStyle(Color.accent)
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
      }

      VStack(alignment: .leading, spacing: Spacing.lg) {
        content()
      }
      .padding(Spacing.lg + 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      )
    }
  }
}
