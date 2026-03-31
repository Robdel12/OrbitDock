import SwiftUI

struct SettingsSidebarButton: View {
  let title: String
  let subtitle: String
  let icon: String
  let isSelected: Bool
  let action: () -> Void

  @State private var isHovering = false

  private var fillColor: Color {
    if isSelected { return Color.surfaceSelected }
    if isHovering { return Color.surfaceHover }
    return Color.clear
  }

  private var borderColor: Color {
    if isSelected { return Color.surfaceBorder }
    if isHovering { return Color.panelBorder.opacity(0.5) }
    return Color.clear
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.md_) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(isSelected ? Color.accent : isHovering ? Color.textSecondary : Color.textTertiary)
          .frame(width: 18)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(title)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(isSelected || isHovering ? Color.textPrimary : Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(subtitle)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, Spacing.lg_)
      .padding(.vertical, Spacing.md_)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(fillColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(borderColor, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    #if os(macOS)
      .onContinuousHover { phase in
        switch phase {
          case .active:
            NSCursor.pointingHand.push()
          case .ended:
            NSCursor.pop()
        }
      }
    #endif
      .animation(Motion.hover, value: isHovering)
      .accessibilityLabel("\(title), \(subtitle)")
      .accessibilityAddTraits(isSelected ? .isSelected : [])
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
      .padding(Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .strokeBorder(Color.panelBorder, lineWidth: 1)
      )
    }
  }
}
