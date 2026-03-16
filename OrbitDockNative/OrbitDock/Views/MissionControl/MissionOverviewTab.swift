import SwiftUI

struct MissionOverviewTab: View {
  let mission: MissionSummary
  let settings: MissionSettings?
  let issues: [MissionIssueItem]
  let missionId: String
  let http: ServerHTTPClient?
  let isCompact: Bool
  let onRefresh: () async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      if mission.orchestratorStatus == "no_api_key" {
        MissionApiKeyBanner(
          missionId: missionId,
          http: http
        ) {
          await onRefresh()
        }
      }

      telemetryStrip

      if let settings {
        configReadout(settings)
      }

      if !issues.isEmpty {
        recentActivitySection
      } else {
        waitingState
      }
    }
  }

  // MARK: - Telemetry Strip

  private var telemetryStrip: some View {
    let gauges = [
      ("Active", mission.activeCount, Color.statusWorking, "bolt.fill"),
      ("Queued", mission.queuedCount, Color.feedbackCaution, "clock.fill"),
      ("Done", mission.completedCount, Color.feedbackPositive, "checkmark.circle.fill"),
      ("Failed", mission.failedCount, Color.feedbackNegative, "xmark.circle.fill"),
    ]

    return Group {
      if isCompact {
        // 2x2 grid on phone
        VStack(spacing: Spacing.sm) {
          HStack(spacing: Spacing.sm) {
            telemetryGauge(label: gauges[0].0, count: gauges[0].1, color: gauges[0].2, icon: gauges[0].3)
            telemetryGauge(label: gauges[1].0, count: gauges[1].1, color: gauges[1].2, icon: gauges[1].3)
          }
          HStack(spacing: Spacing.sm) {
            telemetryGauge(label: gauges[2].0, count: gauges[2].1, color: gauges[2].2, icon: gauges[2].3)
            telemetryGauge(label: gauges[3].0, count: gauges[3].1, color: gauges[3].2, icon: gauges[3].3)
          }
        }
      } else {
        // Single row on desktop
        HStack(spacing: Spacing.sm) {
          ForEach(Array(gauges.enumerated()), id: \.offset) { _, gauge in
            telemetryGauge(label: gauge.0, count: gauge.1, color: gauge.2, icon: gauge.3)
          }
        }
      }
    }
  }

  private func telemetryGauge(label: String, count: UInt32, color: Color, icon: String) -> some View {
    VStack(spacing: Spacing.sm_) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: icon)
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(count > 0 ? color : Color.textQuaternary)

        Text("\(count)")
          .font(.system(size: TypeScale.large, weight: .bold, design: .monospaced))
          .foregroundStyle(count > 0 ? color : Color.textQuaternary)
      }

      Text(label.uppercased())
        .font(.system(size: TypeScale.micro, weight: .bold))
        .foregroundStyle(Color.textQuaternary)
        .tracking(0.8)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(
              count > 0 ? color.opacity(OpacityTier.subtle) : Color.surfaceBorder,
              lineWidth: 1
            )
        )
    )
  }

  // MARK: - Config Readout

  private func configReadout(_ settings: MissionSettings) -> some View {
    let layout = isCompact
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
      : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.sm))

    return layout {
      // Left: Orchestrator status
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm_) {
          signalIndicator
          Text("Orchestrator")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }

        VStack(alignment: .leading, spacing: Spacing.sm_) {
          readoutLine(
            icon: "clock",
            label: "Interval",
            value: settings.trigger.kind == "polling"
              ? formatInterval(settings.trigger.interval)
              : "Manual"
          )
          readoutLine(icon: "person.2", label: "Agents", value: "\(settings.provider.maxConcurrent) max")
          readoutLine(icon: "arrow.clockwise", label: "Retries", value: "\(settings.orchestration.maxRetries)x")
          readoutLine(
            icon: "exclamationmark.triangle",
            label: "Stall",
            value: formatInterval(settings.orchestration.stallTimeout)
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.lg)
      .background(
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .fill(Color.backgroundSecondary)
          .overlay(
            RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
              .strokeBorder(Color.surfaceBorder, lineWidth: 1)
          )
      )

      // Right: Filter summary
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.accent)
          Text("Filters")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }

        if settings.trigger.filters.labels.isEmpty,
           settings.trigger.filters.states.isEmpty,
           settings.trigger.filters.project == nil,
           settings.trigger.filters.team == nil
        {
          Text("All issues")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        } else {
          VStack(alignment: .leading, spacing: Spacing.sm_) {
            if let project = settings.trigger.filters.project {
              readoutLine(icon: "folder", label: "Project", value: project)
            }
            if let team = settings.trigger.filters.team {
              readoutLine(icon: "person.3", label: "Team", value: team)
            }
            if !settings.trigger.filters.labels.isEmpty {
              filterTags(settings.trigger.filters.labels)
            }
            if !settings.trigger.filters.states.isEmpty {
              filterTags(settings.trigger.filters.states)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.lg)
      .background(
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .fill(Color.backgroundSecondary)
          .overlay(
            RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
              .strokeBorder(Color.surfaceBorder, lineWidth: 1)
          )
      )
    }
  }

  private func readoutLine(icon: String, label: String, value: String) -> some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 14)

      Text(label)
        .font(.system(size: TypeScale.micro))
        .foregroundStyle(Color.textTertiary)

      Spacer()

      Text(value)
        .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    }
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

  @ViewBuilder
  private var signalIndicator: some View {
    let isPolling = mission.orchestratorStatus == "polling" || mission.orchestratorStatus == nil
    let color: Color = isPolling ? Color.feedbackPositive
      : mission.orchestratorStatus == "paused" ? Color.feedbackCaution
      : mission.orchestratorStatus == "no_api_key" ? Color.feedbackCaution
      : mission.orchestratorStatus == "config_error" ? Color.feedbackNegative
      : Color.textQuaternary

    Circle()
      .fill(color)
      .frame(width: 6, height: 6)
  }

  // MARK: - Recent Activity

  private var recentActivitySection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      let running = issues.filter { $0.orchestrationState == .running || $0.orchestrationState == .claimed }
      let recentCompleted = issues.filter { $0.orchestrationState == .completed }.prefix(3)
      let failed = issues.filter { $0.orchestrationState == .failed }

      if !running.isEmpty {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "bolt.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.statusWorking)
          Text("Running Now")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }

        ForEach(running) { issue in
          compactIssueRow(issue, accent: Color.statusWorking)
        }
      }

      if !failed.isEmpty {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.feedbackNegative)
          Text("Needs Attention")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }

        ForEach(failed) { issue in
          compactIssueRow(issue, accent: Color.feedbackNegative)
        }
      }

      if !recentCompleted.isEmpty {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.feedbackPositive)
          Text("Recently Completed")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }

        ForEach(recentCompleted) { issue in
          compactIssueRow(issue, accent: Color.feedbackPositive)
        }
      }
    }
  }

  private func compactIssueRow(_ issue: MissionIssueItem, accent: Color) -> some View {
    HStack(spacing: Spacing.md) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(accent)
        .frame(width: EdgeBar.width, height: 24)

      Text(issue.identifier)
        .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.textTertiary)

      Text(issue.title)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)

      Spacer()

      if issue.attempt > 1 {
        Text("#\(issue.attempt)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.feedbackCaution)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
  }

  // MARK: - Waiting State

  private var waitingState: some View {
    let isPolling = mission.orchestratorStatus == "polling"
    let needsKey = mission.orchestratorStatus == "no_api_key"

    return VStack(spacing: Spacing.lg) {
      ZStack {
        // Outer ring
        Circle()
          .strokeBorder(
            (isPolling ? Color.accent : Color.textQuaternary).opacity(OpacityTier.subtle),
            lineWidth: 2
          )
          .frame(width: 56, height: 56)

        // Inner ring
        Circle()
          .strokeBorder(
            (isPolling ? Color.accent : Color.textQuaternary).opacity(OpacityTier.medium),
            lineWidth: 1.5
          )
          .frame(width: 36, height: 36)

        Image(systemName: isPolling ? "antenna.radiowaves.left.and.right" : needsKey ? "key" : "pause")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(isPolling ? Color.accent : Color.textQuaternary)
      }

      VStack(spacing: Spacing.sm_) {
        Text(waitingTitle)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textSecondary)

        Text(waitingSubtitle)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.xxl)
  }

  private var waitingTitle: String {
    switch mission.orchestratorStatus {
      case "polling": "Scanning for issues"
      case "no_api_key": "API key required"
      case "config_error": "Configuration error"
      case "paused": "Orchestrator paused"
      case "disabled": "Mission disabled"
      default: "Orchestrator not started"
    }
  }

  private var waitingSubtitle: String {
    switch mission.orchestratorStatus {
      case "polling":
        "The orchestrator is polling your tracker for matching issues. New issues will appear here automatically."
      case "no_api_key":
        "Set a Linear API key above or via the LINEAR_API_KEY environment variable, then start the orchestrator."
      case "config_error":
        "There's a problem with your WORKFLOW.md configuration. Check the Settings tab for details."
      case "paused":
        "Resume the orchestrator from the actions menu to continue processing issues."
      case "disabled":
        "Enable the mission from the actions menu to start processing issues."
      default:
        "Start the orchestrator from the actions menu to begin polling for issues."
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
}
