import SwiftUI

struct MissionOverviewTab: View {
  let mission: MissionSummary
  let settings: MissionSettings?
  let issues: [MissionIssueItem]
  let missionId: String
  let missionFileExists: Bool
  let workflowMigrationAvailable: Bool
  let http: ServerHTTPClient?
  let isCompact: Bool
  let endpointId: UUID
  let onRefresh: () async -> Void
  let onApplyDetail: (MissionDetailResponse) -> Void
  let onSelectTab: (MissionTab) -> Void
  let onUpdateMission: (Bool?, Bool?) async -> Void
  let onNavigateToSession: (String) -> Void

  @State private var isStartingOrchestrator = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      // Setup flow — unified when migration is available
      if !missionFileExists, settings == nil {
        if workflowMigrationAvailable {
          missionSetupWithMigration
        } else {
          MissionSetupCard(
            missionId: missionId,
            repoRoot: mission.repoRoot,
            http: http,
            onApplyDetail: onApplyDetail,
            onRefresh: onRefresh
          )
        }
      } else if workflowMigrationAvailable {
        workflowMigrationBanner
      }

      if mission.parseError != nil, settings == nil, missionFileExists {
        configNeededBanner
      }

      if mission.orchestratorStatus == "no_api_key" {
        MissionApiKeyBanner(
          missionId: missionId,
          http: http
        ) {
          await onRefresh()
        }
      }

      telemetryStrip

      // Mission Controls (always visible when configured)
      missionControlsSection

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

          if let polledAt = mission.lastPolledAt {
            readoutLine(
              icon: "antenna.radiowaves.left.and.right",
              label: "Last Poll",
              value: relativeTime(polledAt)
            )
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
    let isPolling = mission.orchestratorStatus == "polling"
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
    let running = issues.filter { $0.orchestrationState == .running || $0.orchestrationState == .claimed }
    let queued = issues.filter { $0.orchestrationState == .queued || $0.orchestrationState == .retryQueued }
    let failed = issues.filter { $0.orchestrationState == .failed }
    let completed = issues.filter { $0.orchestrationState == .completed }

    return VStack(alignment: .leading, spacing: Spacing.lg) {
      // Running
      issueGroup(
        "Running", icon: "bolt.fill", color: Color.statusWorking,
        count: running.count, issues: running
      )

      // Failed
      issueGroup(
        "Needs Attention", icon: "exclamationmark.circle.fill", color: Color.feedbackNegative,
        count: failed.count, issues: failed
      )

      // Queued
      issueGroup(
        "Queued", icon: "clock.fill", color: Color.feedbackCaution,
        count: queued.count, issues: queued
      )

      // Completed (show last 5)
      if !completed.isEmpty {
        issueGroup(
          "Completed", icon: "checkmark.circle.fill", color: Color.feedbackPositive,
          count: completed.count, issues: Array(completed.prefix(5))
        )
      }
    }
  }

  private func issueGroup(_ title: String, icon: String, color: Color, count: Int, issues: [MissionIssueItem]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(count > 0 ? color : Color.textQuaternary)
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(count > 0 ? Color.textPrimary : Color.textTertiary)

        if count > 0 {
          Text("\(count)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(
              color.opacity(OpacityTier.subtle),
              in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            )
        }
      }

      if issues.isEmpty {
        Text("None")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)
          .padding(.leading, Spacing.lg)
      } else {
        ForEach(issues) { issue in
          issueDetailRow(issue, accent: color)
        }
      }
    }
  }

  private func issueDetailRow(_ issue: MissionIssueItem, accent: Color) -> some View {
    HStack(spacing: Spacing.sm) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(accent)
        .frame(width: EdgeBar.width)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.sm_) {
          Text(issue.identifier)
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(accent)

          Text(issue.title)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)

          Spacer()

          if issue.attempt > 1 {
            Text("attempt #\(issue.attempt)")
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.feedbackCaution)
          }

          // Provider badge
          Text(issue.provider.capitalized)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          // Tracker state
          Text(issue.trackerState)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(
              Color.backgroundTertiary,
              in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            )

          // Session link
          if issue.sessionId != nil {
            Image(systemName: "arrow.right.circle")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(Color.accent)
          }
        }

        // Error message if failed
        if let error = issue.error, !error.isEmpty {
          Text(error)
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(Color.feedbackNegative.opacity(0.8))
            .lineLimit(2)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .frame(minHeight: 36)
    .background(
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      if let sessionId = issue.sessionId {
        onNavigateToSession(sessionId)
      } else if let url = issue.url, let link = URL(string: url) {
        #if os(macOS)
          NSWorkspace.shared.open(link)
        #endif
      }
    }
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
      case "idle": "Ready to start"
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
        "There's a problem with your MISSION.md configuration. Check the Settings tab for details."
      case "paused":
        "Resume the orchestrator from the actions menu to continue processing issues."
      case "disabled":
        "Enable the mission from the actions menu to start processing issues."
      case "idle":
        "Configuration looks good. Start the orchestrator to begin polling for issues."
      default:
        "Start the orchestrator from the actions menu to begin polling for issues."
    }
  }

  // MARK: - Unified Setup (WORKFLOW.md exists)

  @State private var isScaffoldingFresh = false

  /// When a WORKFLOW.md exists, migration is the hero action.
  /// "Start fresh" is a compact secondary option at the bottom.
  private var missionSetupWithMigration: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      HStack(spacing: Spacing.md) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .fill(Color.accent.opacity(OpacityTier.light))

          Image(systemName: "arrow.right.doc.on.clipboard")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.accent)
        }
        .frame(width: 36, height: 36)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Existing Workflow Found")
            .font(.system(size: TypeScale.large, weight: .bold))
            .foregroundStyle(Color.textPrimary)

          Text("Import your WORKFLOW.md config into a MISSION.md")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
        }
      }
      .padding(Spacing.lg)
      .padding(.top, Spacing.xs)

      Divider().foregroundStyle(Color.surfaceBorder)

      // Import action
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "doc.text")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)

          Text(mission.repoRoot + "/WORKFLOW.md")
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Button {
          Task { await migrateWorkflow() }
        } label: {
          HStack(spacing: Spacing.sm) {
            if isMigrating {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.right.doc")
            }
            Text("Import Settings")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(CosmicButtonStyle(color: .accent, size: .large))
        .disabled(isMigrating)
      }
      .padding(Spacing.lg)

      Divider().foregroundStyle(Color.surfaceBorder)

      // Secondary: start fresh
      HStack(spacing: Spacing.sm_) {
        Text("Or")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)

        Button {
          Task { await scaffoldFresh() }
        } label: {
          HStack(spacing: Spacing.xs) {
            if isScaffoldingFresh {
              ProgressView()
                .controlSize(.mini)
            } else {
              Image(systemName: "wand.and.stars")
                .font(.system(size: 9))
            }
            Text("start fresh with a blank MISSION.md")
              .font(.system(size: TypeScale.micro))
          }
          .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
        .disabled(isScaffoldingFresh)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .strokeBorder(
          LinearGradient(
            colors: [
              Color.accent.opacity(OpacityTier.medium),
              Color.accent.opacity(OpacityTier.subtle),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 1
        )
    )
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
  }

  private func scaffoldFresh() async {
    guard let http else { return }
    isScaffoldingFresh = true
    do {
      let response: MissionDetailResponse = try await http.post(
        "/api/missions/\(missionId)/scaffold",
        body: EmptyBody()
      )
      onApplyDetail(response)
    } catch {
      print("[OrbitDock] Failed to scaffold: \(error)")
      await onRefresh()
    }
    isScaffoldingFresh = false
  }

  // MARK: - Workflow Migration Banner (standalone, when MISSION.md already exists)

  @State private var isMigrating = false

  private var workflowMigrationBanner: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.right.arrow.left.circle.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.accent)
        Text("Migrate from WORKFLOW.md")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
      }

      Text(
        "A WORKFLOW.md with compatible settings was found. Import your tracker, polling, and provider settings into a new MISSION.md."
      )
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)

      Button {
        Task { await migrateWorkflow() }
      } label: {
        HStack(spacing: Spacing.sm) {
          if isMigrating {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.right.doc")
          }
          Text("Import Settings")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(CosmicButtonStyle(color: .accent, size: .large))
      .disabled(isMigrating)
    }
    .statusBanner(color: Color.accent)
  }

  private func migrateWorkflow() async {
    guard let http else { return }
    isMigrating = true
    do {
      let response: MissionDetailResponse = try await http.post(
        "/api/missions/\(missionId)/migrate-workflow",
        body: EmptyBody()
      )
      onApplyDetail(response)
    } catch {
      print("[OrbitDock] Failed to migrate workflow: \(error)")
      await onRefresh()
    }
    isMigrating = false
  }

  // MARK: - Config Needed Banner

  private var configNeededBanner: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "info.circle.fill")
          .foregroundStyle(Color.feedbackCaution)
        Text("Configuration Needed")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
      }

      Text(
        "Your MISSION.md doesn't contain OrbitDock configuration yet. Open Settings to configure — your existing file content will be preserved."
      )
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)

      Button {
        onSelectTab(.settings)
      } label: {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "gearshape")
          Text("Open Settings")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(CosmicButtonStyle(color: .accent, size: .large))
    }
    .statusBanner(color: Color.feedbackCaution)
  }

  // MARK: - Mission Controls

  private var missionControlsSection: some View {
    let isPolling = mission.orchestratorStatus == "polling"
    let isIdle = mission.orchestratorStatus == "idle" || mission.orchestratorStatus == nil
    let canStart = mission.enabled && !mission.paused && isIdle
    let canPause = mission.enabled && isPolling && !mission.paused
    let canResume = mission.enabled && mission.paused

    return VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm_) {
        signalIndicator
        Text("Mission Controls")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
        Spacer()
        Text(mission.statusLabel)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(mission.statusColor)
      }

      let layout = isCompact
        ? AnyLayout(VStackLayout(spacing: Spacing.sm))
        : AnyLayout(HStackLayout(spacing: Spacing.sm))

      layout {
        controlButton(
          "Start",
          icon: "play.fill",
          style: .primary,
          enabled: canStart
        ) {
          await startOrchestrator()
        }

        controlButton(
          canResume ? "Resume" : "Pause",
          icon: canResume ? "play.fill" : "pause.fill",
          style: .secondary,
          enabled: canPause || canResume
        ) {
          if canResume {
            await onUpdateMission(nil, false)
          } else {
            await onUpdateMission(nil, true)
          }
        }

        controlButton(
          mission.enabled ? "Disable" : "Enable",
          icon: mission.enabled ? "stop.circle" : "play.circle",
          style: mission.enabled ? .destructive : .primary,
          enabled: true
        ) {
          await onUpdateMission(!mission.enabled, nil)
        }
      }

      Text("Operational state — not saved to MISSION.md")
        .font(.system(size: TypeScale.micro))
        .foregroundStyle(Color.textQuaternary)
    }
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

  private enum ControlButtonStyle { case primary, secondary, destructive }

  private func controlButton(
    _ title: String,
    icon: String,
    style: ControlButtonStyle,
    enabled: Bool,
    action: @escaping () async -> Void
  ) -> some View {
    let fgColor: Color = if !enabled {
      Color.textQuaternary
    } else if style == .primary {
      .white
    } else if style == .destructive {
      Color.feedbackNegative
    } else {
      Color.textSecondary
    }

    let bgColor: Color = if !enabled {
      Color.backgroundTertiary.opacity(0.5)
    } else if style == .primary {
      Color.accent
    } else {
      Color.backgroundTertiary
    }

    return Button {
      Task { await action() }
    } label: {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: icon)
          .font(.system(size: 11, weight: .semibold))
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
      }
      .foregroundStyle(fgColor)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.md_)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(bgColor)
      )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  private func startOrchestrator() async {
    guard let http else { return }
    isStartingOrchestrator = true
    do {
      let _: MissionOkResponse = try await http.post(
        "/api/missions/\(missionId)/start-orchestrator",
        body: EmptyBody()
      )
    } catch {
      print("[OrbitDock] Failed to start orchestrator: \(error)")
    }
    isStartingOrchestrator = false
    await onRefresh()
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
      // Try without fractional seconds
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
    if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
    return "\(Int(elapsed / 3600))h ago"
  }
}

