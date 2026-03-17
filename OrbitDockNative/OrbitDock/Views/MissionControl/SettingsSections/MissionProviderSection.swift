import SwiftUI

struct MissionProviderSection: View {
  @Binding var providerStrategy: String
  @Binding var primaryProvider: String
  @Binding var secondaryProvider: String
  @Binding var maxConcurrent: UInt32
  @Binding var maxConcurrentPrimary: UInt32
  let isCompact: Bool

  var body: some View {
    missionInstrumentPanel(
      title: "Provider",
      icon: "cpu",
      description: "Which AI agents handle your issues",
      isCompact: isCompact
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          missionSectionLabel("Dispatch Strategy")

          VStack(spacing: Spacing.xs) {
            strategyOption(
              title: "Single",
              description: "One provider handles all issues",
              value: "single"
            )
            strategyOption(
              title: "Priority",
              description: "Primary first, overflow to secondary",
              value: "priority"
            )
            strategyOption(
              title: "Round Robin",
              description: "Alternate between providers",
              value: "round_robin"
            )
          }
        }

        ProviderSelectionGroup(
          strategy: $providerStrategy,
          primary: $primaryProvider,
          secondary: $secondaryProvider,
          includeStrategy: false,
          useCardStyle: true
        )

        missionConcurrencyStepper("Max Concurrent", value: $maxConcurrent, range: 1 ... 20)

        if providerStrategy == "priority" {
          missionConcurrencyStepper("Primary Limit", value: $maxConcurrentPrimary, range: 1 ... 20)
        }
      }
    }
  }

  private func strategyOption(title: String, description: String, value: String) -> some View {
    Button {
      withAnimation(Motion.snappy) { providerStrategy = value }
    } label: {
      HStack(spacing: Spacing.md) {
        ZStack {
          Circle()
            .strokeBorder(providerStrategy == value ? Color.accent : Color.textQuaternary, lineWidth: 1.5)
            .frame(width: 14, height: 14)

          if providerStrategy == value {
            Circle()
              .fill(Color.accent)
              .frame(width: 7, height: 7)
          }
        }

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(providerStrategy == value ? Color.textPrimary : Color.textSecondary)

          Text(description)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(providerStrategy == value ? Color.accent.opacity(OpacityTier.subtle) : Color.backgroundTertiary
            .opacity(0.5))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .strokeBorder(providerStrategy == value ? Color.accent.opacity(OpacityTier.light) : .clear, lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }
}
