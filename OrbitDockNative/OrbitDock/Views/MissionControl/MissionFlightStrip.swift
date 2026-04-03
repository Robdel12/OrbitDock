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
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(statusColor.opacity(OpacityTier.subtle), lineWidth: 1)
        )
    )
    .overlay(alignment: .top) {
      // Accent gradient line — status-driven color
      UnevenRoundedRectangle(
        cornerRadii: .init(topLeading: CGFloat(Radius.md), topTrailing: CGFloat(Radius.md)),
        style: .continuous
      )
      .fill(
        LinearGradient(
          colors: [statusColor.opacity(0.6), statusColor.opacity(OpacityTier.light), .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .frame(height: 2)
    }
    .themeShadow(Shadow.glow(color: statusColor, intensity: isPolling ? 0.12 : 0.04))
  }

  // MARK: - Desktop Layout

  private var desktopBody: some View {
    HStack(spacing: Spacing.lg) {
      statusIndicator

      // Divider
      Rectangle()
        .fill(Color.surfaceBorder)
        .frame(width: 1, height: 20)

      MissionPollCountdown(
        nextTickAt: nextTickAt,
        lastTickAt: lastTickAt,
        isPolling: isPolling
      )

      Spacer()

      instrumentPanel

      // Divider
      Rectangle()
        .fill(Color.surfaceBorder)
        .frame(width: 1, height: 20)

      controlButtons
    }
    .padding(.vertical, Spacing.md)
    .padding(.horizontal, Spacing.lg)
    .frame(minHeight: 44)
  }

  // MARK: - Compact Layout

  private var compactBody: some View {
    VStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        statusIndicator

        Spacer()

        controlButtons
      }

      HStack(spacing: Spacing.sm) {
        MissionPollCountdown(
          nextTickAt: nextTickAt,
          lastTickAt: lastTickAt,
          isPolling: isPolling
        )

        Spacer()

        instrumentPanel
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
          // Outer pulse ring
          Circle()
            .stroke(statusColor.opacity(OpacityTier.light), lineWidth: 1)
            .frame(width: 18, height: 18)
            .scaleEffect(isPolling ? 1.0 : 0.6)
            .opacity(isPolling ? 1.0 : 0.0)
            .animation(
              Motion.animationsEnabled ? .easeInOut(duration: 1.8).repeatForever(autoreverses: true) : nil,
              value: isPolling
            )

          // Inner pulse ring
          Circle()
            .fill(statusColor.opacity(OpacityTier.light))
            .frame(width: 14, height: 14)
            .animation(
              Motion.animationsEnabled ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true) : nil,
              value: isPolling
            )
        }

        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)
      }
      .frame(width: 18, height: 18)

      Text(statusLabel)
        .font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(statusColor)
    }
  }

  // MARK: - Instrument Panel (stat counters)

  private var instrumentPanel: some View {
    HStack(spacing: isCompact ? Spacing.sm : Spacing.lg) {
      gauge(
        value: mission.activeCount,
        label: "ACTIVE",
        icon: "bolt.fill",
        color: .statusWorking
      )
      gauge(
        value: mission.queuedCount,
        label: "QUEUE",
        icon: "clock.fill",
        color: .feedbackCaution
      )
      gauge(
        value: mission.completedCount,
        label: "DONE",
        icon: "checkmark.circle.fill",
        color: .feedbackPositive
      )
      gauge(
        value: mission.failedCount,
        label: "ALERT",
        icon: "xmark.circle.fill",
        color: .feedbackNegative,
        isUrgent: mission.failedCount > 0
      )
    }
  }

  private func gauge(
    value: UInt32,
    label: String,
    icon: String,
    color: Color,
    isUrgent: Bool = false
  ) -> some View {
    VStack(spacing: Spacing.xxs) {
      HStack(spacing: Spacing.xxs) {
        Image(systemName: icon)
          .font(.system(size: 7, weight: .bold))

        Text("\(value)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
      }
      .foregroundStyle(value > 0 ? color : Color.textQuaternary)

      Text(label)
        .font(.system(size: 8, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .tracking(0.5)
    }
    .padding(.horizontal, isUrgent ? Spacing.xs : 0)
    .padding(.vertical, isUrgent ? Spacing.xxs : 0)
    .background(
      isUrgent
        ? color.opacity(OpacityTier.subtle)
        : Color.clear,
      in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
    )
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
        .frame(width: 26, height: 26)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
            .fill(enabled ? color.opacity(OpacityTier.subtle) : Color.backgroundTertiary.opacity(0.5))
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
            .strokeBorder(enabled ? color.opacity(OpacityTier.subtle) : .clear, lineWidth: 0.5)
        )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}
