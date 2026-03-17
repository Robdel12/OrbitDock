import SwiftUI

struct MissionCommandCenter: View {
  let mission: MissionSummary
  let settings: MissionSettings?
  let isCompact: Bool
  let onUpdateMission: (Bool?, Bool?) async -> Void
  let onStartOrchestrator: () async -> Void

  private var totalIssueCount: UInt32 {
    mission.activeCount + mission.queuedCount + mission.completedCount + mission.failedCount
  }

  var body: some View {
    let isPolling = mission.orchestratorStatus == "polling"
    let isIdle = mission.orchestratorStatus == "idle" || mission.orchestratorStatus == nil
    let canStart = mission.enabled && !mission.paused && isIdle
    let canPause = mission.enabled && isPolling && !mission.paused
    let canResume = mission.enabled && mission.paused

    VStack(alignment: .leading, spacing: 0) {
      // Row 1: Status + Controls
      HStack(spacing: Spacing.sm) {
        // Status signal
        ZStack {
          if isPolling {
            Circle()
              .fill(Color.feedbackPositive.opacity(OpacityTier.light))
              .frame(width: 18, height: 18)
          }
          Circle()
            .fill(mission.statusColor)
            .frame(width: 7, height: 7)
        }
        .frame(width: 18, height: 18)

        Text(mission.statusLabel)
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(mission.statusColor)

        Spacer()

        // Compact control buttons
        HStack(spacing: Spacing.xs) {
          controlIcon(
            icon: "play.fill",
            color: Color.feedbackPositive,
            enabled: canStart
          ) {
            await onStartOrchestrator()
          }

          controlIcon(
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

          controlIcon(
            icon: mission.enabled ? "stop.fill" : "power",
            color: mission.enabled ? Color.feedbackNegative : Color.feedbackPositive,
            enabled: true
          ) {
            await onUpdateMission(!mission.enabled, nil)
          }
        }
      }
      .padding(Spacing.lg)

      // Progress segment bar
      if totalIssueCount > 0 {
        pipelineBar
          .padding(.horizontal, Spacing.lg)
          .padding(.bottom, Spacing.sm)
      }

      Divider().foregroundStyle(Color.surfaceBorder)

      // Row 2: Telemetry counters
      HStack(spacing: isCompact ? Spacing.md : Spacing.xl) {
        MissionStatChip(count: mission.activeCount, label: "active", color: .statusWorking, style: .icon("bolt.fill"))
        MissionStatChip(
          count: mission.queuedCount,
          label: "queued",
          color: .feedbackCaution,
          style: .icon("clock.fill")
        )
        MissionStatChip(
          count: mission.completedCount,
          label: "done",
          color: .feedbackPositive,
          style: .icon("checkmark.circle.fill")
        )
        MissionStatChip(
          count: mission.failedCount,
          label: "failed",
          color: .feedbackNegative,
          style: .icon("xmark.circle.fill")
        )
        Spacer()
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)

      // Row 3: Config context
      if let settings {
        Divider().foregroundStyle(Color.surfaceBorder)
        configContextRows(settings)
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.md)
      }
    }
    .cosmicCard(cornerRadius: Radius.ml, fillColor: .backgroundSecondary, fillOpacity: 1.0, borderOpacity: 1.0)
    .overlay(alignment: .top) {
      // Status-colored top glow edge
      UnevenRoundedRectangle(
        cornerRadii: .init(topLeading: CGFloat(Radius.ml), topTrailing: CGFloat(Radius.ml)),
        style: .continuous
      )
      .fill(
        LinearGradient(
          colors: [mission.statusColor.opacity(OpacityTier.medium), .clear],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .frame(height: 3)
    }
  }

  // MARK: - Control Icon

  private func controlIcon(
    icon: String,
    color: Color,
    enabled: Bool,
    action: @escaping () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(enabled ? color : Color.textQuaternary)
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
            .fill(enabled ? color.opacity(OpacityTier.subtle) : Color.backgroundTertiary.opacity(0.5))
        )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  // MARK: - Pipeline Bar

  private var pipelineBar: some View {
    let total = totalIssueCount

    return GeometryReader { geo in
      let w = geo.size.width
      let fTotal = CGFloat(total)

      HStack(spacing: 0) {
        if mission.completedCount > 0 {
          Rectangle()
            .fill(Color.feedbackPositive)
            .frame(width: max(3, w * CGFloat(mission.completedCount) / fTotal))
        }
        if mission.activeCount > 0 {
          Rectangle()
            .fill(Color.statusWorking)
            .frame(width: max(3, w * CGFloat(mission.activeCount) / fTotal))
        }
        if mission.queuedCount > 0 {
          Rectangle()
            .fill(Color.feedbackCaution)
            .frame(width: max(3, w * CGFloat(mission.queuedCount) / fTotal))
        }
        if mission.failedCount > 0 {
          Rectangle()
            .fill(Color.feedbackNegative)
            .frame(width: max(3, w * CGFloat(mission.failedCount) / fTotal))
        }
      }
    }
    .frame(height: 3)
    .clipShape(Capsule())
  }

  // MARK: - Config Context

  private func configContextRows(_ settings: MissionSettings) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(spacing: Spacing.lg) {
        configItem(
          icon: "antenna.radiowaves.left.and.right",
          value: settings.trigger.kind == "polling"
            ? "Every \(formatInterval(settings.trigger.interval))"
            : "Manual"
        )

        if let polledAt = mission.lastPolledAt {
          configItem(icon: "clock", value: relativeTime(polledAt))
        }

        configItem(icon: "person.2", value: "\(settings.provider.maxConcurrent) max")
        configItem(icon: "arrow.clockwise", value: "\(settings.orchestration.maxRetries)x")

        Spacer()
      }

      let filters = settings.trigger.filters
      if filters.project != nil || filters.team != nil
        || !filters.labels.isEmpty || !filters.states.isEmpty
      {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.textQuaternary)

          if let project = filters.project {
            filterBadge(icon: "folder", text: project)
          }

          if let team = filters.team {
            filterBadge(icon: "person.3", text: team)
          }

          if !filters.states.isEmpty {
            filterTags(filters.states)
          }

          if !filters.labels.isEmpty {
            filterTags(filters.labels)
          }
        }
      }
    }
  }

  private func configItem(icon: String, value: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Color.textQuaternary)

      Text(value)
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
    }
  }

  private func filterBadge(icon: String, text: String) -> some View {
    HStack(spacing: Spacing.xxs) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .medium))
      Text(text)
        .lineLimit(1)
    }
    .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
    .foregroundStyle(Color.textTertiary)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, 2)
    .background(
      Color.backgroundTertiary,
      in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
    )
  }

  private func filterTags(_ tags: [String]) -> some View {
    HStack(spacing: Spacing.xs) {
      ForEach(tags, id: \.self) { tag in
        Text(tag)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.accent)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 2)
          .background(
            Color.accent.opacity(OpacityTier.subtle),
            in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          )
      }
    }
  }

  // MARK: - Helpers

  private func formatInterval(_ seconds: UInt64) -> String {
    if seconds >= 3_600 {
      let h = seconds / 3_600
      let m = (seconds % 3_600) / 60
      return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    } else if seconds >= 60 {
      return "\(seconds / 60)m"
    } else {
      return "\(seconds)s"
    }
  }

  private func relativeTime(_ iso8601: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: iso8601) else {
      formatter.formatOptions = [.withInternetDateTime]
      guard let date = formatter.date(from: iso8601) else { return iso8601 }
      return relativeTimeFromDate(date)
    }
    return relativeTimeFromDate(date)
  }

  private func relativeTimeFromDate(_ date: Date) -> String {
    let elapsed = Date().timeIntervalSince(date)
    if elapsed < 5 { return "just now" }
    if elapsed < 60 { return "\(Int(elapsed))s ago" }
    if elapsed < 3_600 { return "\(Int(elapsed / 60))m ago" }
    return "\(Int(elapsed / 3_600))h ago"
  }
}
