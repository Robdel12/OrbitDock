import SwiftUI

struct MissionFlightStrip: View {
  let mission: MissionSummary
  let nextTickAt: Date?
  let lastTickAt: Date?
  let isCompact: Bool
  let onUpdateMission: (Bool?, Bool?) async -> Void
  let onStartOrchestrator: () async -> Void
  let onTriggerPoll: () async -> Void

  private var isPolling: Bool {
    mission.orchestratorStatus == "polling"
  }

  private var isIdle: Bool {
    mission.orchestratorStatus == "idle" || mission.orchestratorStatus == nil
  }

  private var canStart: Bool {
    mission.enabled && !mission.paused && isIdle
  }

  private var canPause: Bool {
    mission.enabled && isPolling && !mission.paused
  }

  private var canResume: Bool {
    mission.enabled && mission.paused
  }

  private var statusLabel: String {
    mission.flightStatus
  }

  private var statusColor: Color {
    mission.flightStatusColor
  }

  // MARK: - Body

  var body: some View {
    Group {
      if isCompact {
        compactBody
      } else {
        desktopBody
      }
    }
    .cosmicCard(cornerRadius: Radius.md, fillColor: .backgroundSecondary, fillOpacity: 1.0, borderOpacity: 1.0)
    .overlay(alignment: .top) {
      UnevenRoundedRectangle(
        cornerRadii: .init(topLeading: CGFloat(Radius.md), topTrailing: CGFloat(Radius.md)),
        style: .continuous
      )
      .fill(
        LinearGradient(
          colors: [statusColor.opacity(OpacityTier.medium), .clear],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .frame(height: 2)
    }
  }

  // MARK: - Desktop Layout (unchanged)

  private var desktopBody: some View {
    HStack(spacing: Spacing.md) {
      statusIndicator

      MissionPollCountdown(
        nextTickAt: nextTickAt,
        lastTickAt: lastTickAt,
        isPolling: isPolling
      )

      Spacer()

      statCounters

      controlButtons
    }
    .padding(.vertical, Spacing.md)
    .padding(.horizontal, Spacing.lg)
    .frame(minHeight: 40)
  }

  // MARK: - Compact Layout

  private var compactBody: some View {
    VStack(spacing: Spacing.sm) {
      // Row 1: Status + controls
      HStack(spacing: Spacing.sm) {
        statusIndicator

        Spacer()

        controlButtons
      }

      // Row 2: Countdown + stat counters
      HStack(spacing: Spacing.sm) {
        MissionPollCountdown(
          nextTickAt: nextTickAt,
          lastTickAt: lastTickAt,
          isPolling: isPolling
        )

        Spacer()

        statCounters
      }
    }
    .padding(.vertical, Spacing.md)
    .padding(.horizontal, Spacing.lg)
  }

  // MARK: - Status Indicator

  private var statusIndicator: some View {
    HStack(spacing: Spacing.sm_) {
      ZStack {
        if isPolling {
          Circle()
            .fill(statusColor.opacity(OpacityTier.light))
            .frame(width: 14, height: 14)
            .animation(
              .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
              value: isPolling
            )
        }
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)
      }
      .frame(width: 14, height: 14)

      Text(statusLabel)
        .font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(statusColor)
    }
  }

  // MARK: - Stat Counters

  private var statCounters: some View {
    HStack(spacing: isCompact ? Spacing.sm : Spacing.md) {
      inlineStat(icon: "bolt.fill", count: mission.activeCount, color: .statusWorking)
      inlineStat(icon: "clock.fill", count: mission.queuedCount, color: .feedbackCaution)
      inlineStat(icon: "checkmark.circle.fill", count: mission.completedCount, color: .feedbackPositive)

      inlineStat(icon: "xmark.circle.fill", count: mission.failedCount, color: .feedbackNegative)
        .padding(.horizontal, mission.failedCount > 0 ? Spacing.xs : 0)
        .padding(.vertical, mission.failedCount > 0 ? Spacing.xxs : 0)
        .background(
          mission.failedCount > 0
            ? Color.feedbackNegative.opacity(OpacityTier.subtle)
            : Color.clear,
          in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
        )
    }
  }

  private func inlineStat(icon: String, count: UInt32, color: Color) -> some View {
    HStack(spacing: Spacing.xxs) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(count > 0 ? color : Color.textQuaternary)

      Text("\(count)")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
        .foregroundStyle(count > 0 ? color : Color.textQuaternary)
    }
  }

  // MARK: - Control Buttons

  private var controlButtons: some View {
    HStack(spacing: Spacing.xs) {
      controlButton(
        icon: "arrow.clockwise",
        color: Color.accent,
        enabled: isPolling
      ) {
        await onTriggerPoll()
      }

      controlButton(
        icon: "play.fill",
        color: Color.feedbackPositive,
        enabled: canStart
      ) {
        await onStartOrchestrator()
      }

      controlButton(
        icon: canResume ? "play.fill" : "pause.fill",
        color: canResume ? Color.accent : Color.feedbackCaution,
        enabled: canPause || canResume
      ) {
        if canResume {
          await onUpdateMission(nil, false)
        } else {
          await onUpdateMission(nil, true)
        }
      }

      controlButton(
        icon: mission.enabled ? "stop.fill" : "power",
        color: mission.enabled ? Color.feedbackNegative : Color.feedbackPositive,
        enabled: true
      ) {
        await onUpdateMission(!mission.enabled, nil)
      }
    }
  }

  private func controlButton(
    icon: String,
    color: Color,
    enabled: Bool,
    action: @escaping () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(enabled ? color : Color.textQuaternary)
        .frame(width: 24, height: 24)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
            .fill(enabled ? color.opacity(OpacityTier.subtle) : Color.backgroundTertiary.opacity(0.5))
        )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}
