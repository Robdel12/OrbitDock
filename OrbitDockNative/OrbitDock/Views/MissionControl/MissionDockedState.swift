import SwiftUI

struct MissionDockedState: View {
  let mission: MissionSummary
  let onStartOrchestrator: () async -> Void
  let onUpdateMission: (Bool?, Bool?) async -> Void

  private var totalCount: UInt32 {
    mission.activeCount + mission.queuedCount + mission.completedCount + mission.failedCount
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Spacer()

      Text("Docked")
        .font(.system(size: TypeScale.title, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      // Stat blocks
      HStack(spacing: Spacing.md) {
        statBlock(
          count: mission.completedCount,
          label: "done",
          color: Color.feedbackPositive,
          dimWhenZero: false
        )
        statBlock(
          count: mission.failedCount,
          label: "failed",
          color: Color.feedbackNegative,
          dimWhenZero: true
        )
        statBlock(
          count: totalCount,
          label: "total",
          color: Color.textSecondary,
          dimWhenZero: false
        )
        statBlock(
          count: mission.queuedCount,
          label: "queued",
          color: Color.feedbackCaution,
          dimWhenZero: true
        )
      }

      // CTA text
      Text(ctaText)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
        .multilineTextAlignment(.center)

      Spacer()
    }
    .padding(.vertical, Spacing.xxl)
  }

  // MARK: - Stat Block

  private func statBlock(
    count: UInt32,
    label: String,
    color: Color,
    dimWhenZero: Bool
  ) -> some View {
    let displayColor = dimWhenZero && count == 0 ? Color.textQuaternary : color

    return VStack(spacing: Spacing.xs) {
      Text("\(count)")
        .font(.system(size: TypeScale.large, weight: .bold, design: .monospaced))
        .foregroundStyle(displayColor)

      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
    .frame(minWidth: 64)
    .padding(.vertical, Spacing.md)
    .padding(.horizontal, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(Color.backgroundTertiary)
    )
  }

  // MARK: - CTA Text

  private var ctaText: String {
    if !mission.enabled {
      return "Enable to start processing issues"
    }
    if mission.paused {
      return "Resume to continue polling"
    }
    if mission.orchestratorStatus == "no_api_key" {
      return "Set a Linear API key to begin"
    }
    // Idle / not started
    return "Start the orchestrator to begin polling"
  }
}
