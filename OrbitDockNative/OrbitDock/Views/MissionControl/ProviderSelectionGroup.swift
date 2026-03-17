import SwiftUI

struct ProviderSelectionGroup: View {
  @Binding var strategy: String
  @Binding var primary: String
  @Binding var secondary: String
  var isCompact: Bool = false
  var includeStrategy: Bool = true
  var useCardStyle: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      if includeStrategy {
        strategyRow
      }

      primaryRow
      secondaryRow
    }
  }

  // MARK: - Strategy

  private var strategyRow: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      fieldLabel("Strategy")

      HStack(spacing: Spacing.sm) {
        chipButton("Single", value: "single", selected: $strategy)
        chipButton("Priority", value: "priority", selected: $strategy)
        chipButton("Round Robin", value: "round_robin", selected: $strategy)
      }
    }
  }

  // MARK: - Primary

  private var primaryRow: some View {
    VStack(alignment: .leading, spacing: useCardStyle ? Spacing.sm_ : Spacing.xs) {
      fieldLabel(useCardStyle ? "Primary" : "Primary Provider")

      HStack(spacing: Spacing.sm) {
        if useCardStyle {
          providerCard("Claude", value: "claude", icon: "cpu", binding: $primary)
          providerCard("Codex", value: "codex", icon: "terminal", binding: $primary)
        } else {
          chipButton("Claude", value: "claude", selected: $primary)
          chipButton("Codex", value: "codex", selected: $primary)
        }
      }
    }
  }

  // MARK: - Secondary

  @ViewBuilder
  private var secondaryRow: some View {
    if strategy != "single" {
      VStack(alignment: .leading, spacing: useCardStyle ? Spacing.sm_ : Spacing.xs) {
        fieldLabel(useCardStyle ? "Secondary" : "Secondary Provider")

        HStack(spacing: Spacing.sm) {
          if useCardStyle {
            providerCard("Claude", value: "claude", icon: "cpu", binding: $secondary)
            providerCard("Codex", value: "codex", icon: "terminal", binding: $secondary)
            providerCard("None", value: "", icon: "minus", binding: $secondary)
          } else {
            chipButton("Claude", value: "claude", selected: $secondary)
            chipButton("Codex", value: "codex", selected: $secondary)
            chipButton("None", value: "", selected: $secondary)
          }
        }
      }
    }
  }

  // MARK: - Helpers

  private func fieldLabel(_ text: String) -> some View {
    Group {
      if useCardStyle {
        Text(text.uppercased())
          .font(.system(size: TypeScale.micro, weight: .bold))
          .foregroundStyle(Color.textQuaternary)
          .tracking(0.6)
      } else {
        Text(text)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  private func chipButton(_ label: String, value: String, selected: Binding<String>) -> some View {
    Button {
      selected.wrappedValue = value
    } label: {
      SelectableOptionChip(
        label: label,
        isSelected: selected.wrappedValue == value
      )
    }
    .buttonStyle(.plain)
  }

  private func providerCard(_ label: String, value: String, icon: String, binding: Binding<String>) -> some View {
    let isSelected = binding.wrappedValue == value

    return Button {
      withAnimation(Motion.snappy) { binding.wrappedValue = value }
    } label: {
      VStack(spacing: Spacing.sm_) {
        Image(systemName: icon)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(isSelected ? Color.accent : Color.textTertiary)

        Text(label)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.md)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(isSelected ? Color.accent.opacity(OpacityTier.subtle) : Color.backgroundTertiary.opacity(0.5))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .strokeBorder(
                isSelected ? Color.accent.opacity(OpacityTier.medium) : Color.surfaceBorder.opacity(OpacityTier.subtle),
                lineWidth: 1
              )
          )
      )
    }
    .buttonStyle(.plain)
  }
}
