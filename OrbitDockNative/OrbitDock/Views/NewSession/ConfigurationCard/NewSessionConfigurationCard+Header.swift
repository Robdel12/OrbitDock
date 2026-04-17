import SwiftUI

extension NewSessionConfigurationCard {
  var configurationHeader: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .center, spacing: Spacing.sm) {
        Circle()
          .fill(headerTint.opacity(OpacityTier.light))
          .frame(width: 28, height: 28)
          .overlay(
            Image(systemName: headerIcon)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(headerTint)
          )

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(headerTitle)
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(headerSubtitle)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()
      }

      codexStatusStrip
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.top, Spacing.lg)
    .padding(.bottom, Spacing.md)
  }

  var headerIcon: String {
    switch provider {
      case .claude:
        "slider.horizontal.3"
      case .codex:
        "slider.horizontal.3"
    }
  }

  var headerTint: Color {
    switch provider {
      case .claude:
        .providerClaude
      case .codex:
        .providerCodex
    }
  }

  var headerTitle: String {
    switch provider {
      case .claude:
        "Session Behavior"
      case .codex:
        "Session Behavior"
    }
  }

  var headerSubtitle: String {
    switch provider {
      case .claude:
        "Pick the model, permission posture, and reasoning effort before launch."
      case .codex:
        "Choose a folder when you want Codex to resolve project defaults, or jump straight to a saved profile or custom launch."
    }
  }

  var codexStatusStrip: some View {
    HStack(spacing: Spacing.sm) {
      if provider == .codex {
        codexHeaderBadge(
          title: codexConfigMode == .inherit ? "Inherited" : codexConfigMode == .profile ? "Saved Profile" :
            "Custom Session",
          tint: Color.providerCodex
        )

        if let displayName = currentCodexModelOption?.displayName {
          codexHeaderBadge(title: displayName, tint: Color.accent)
        }
      } else {
        codexHeaderBadge(title: claudeModelId.isEmpty ? "Model Pending" : claudeModelId, tint: Color.providerClaude)
        codexHeaderBadge(title: selectedPermissionMode.displayName, tint: selectedPermissionMode.color)
      }

      Spacer(minLength: Spacing.sm)
    }
  }

  func codexHeaderBadge(title: String, tint: Color) -> some View {
    Text(title)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.gap)
      .background(tint.opacity(OpacityTier.light), in: Capsule())
      .overlay(
        Capsule()
          .stroke(tint.opacity(OpacityTier.medium), lineWidth: 1)
      )
  }
}
