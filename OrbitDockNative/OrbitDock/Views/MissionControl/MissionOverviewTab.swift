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
  let sessionStore: SessionStore?
  let onRefresh: () async -> Void
  let onApplyDetail: (MissionDetailResponse) -> Void
  let onSelectTab: (MissionTab) -> Void
  let onUpdateMission: (Bool?, Bool?) async -> Void
  let onNavigateToSession: (String) -> Void

  @State private var isStartingOrchestrator = false

  // Computed issue groups — filtered once, used everywhere
  private var runningIssues: [MissionIssueItem] {
    issues.filter { $0.orchestrationState == .running || $0.orchestrationState == .claimed }
  }

  private var failedIssues: [MissionIssueItem] {
    issues.filter { $0.orchestrationState == .failed }
  }

  private var queuedIssues: [MissionIssueItem] {
    issues.filter { $0.orchestrationState == .queued || $0.orchestrationState == .retryQueued }
  }

  private var completedIssues: [MissionIssueItem] {
    issues.filter { $0.orchestrationState == .completed }
  }

  private var totalIssueCount: UInt32 {
    mission.activeCount + mission.queuedCount + mission.completedCount + mission.failedCount
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      // Setup flows (unchanged)
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
        MissionApiKeyBanner(missionId: missionId, http: http) {
          await onRefresh()
        }
      }

      // ── Command Center ─────────────────────────────────────
      // Unified status + telemetry + controls + config context
      commandCenter

      // ── Active Threads ─────────────────────────────────────
      // Running agent cards — the hero of the dashboard
      if !runningIssues.isEmpty {
        activeThreadsSection
      }

      // ── Needs Attention ────────────────────────────────────
      // Failed issues — only shown when there ARE failures
      if !failedIssues.isEmpty {
        attentionSection
      }

      // ── Queued ─────────────────────────────────────────────
      if !queuedIssues.isEmpty {
        queueSection
      }

      // ── Completed ──────────────────────────────────────────
      if !completedIssues.isEmpty {
        completedSection
      }

      // ── Empty State ────────────────────────────────────────
      if issues.isEmpty {
        waitingState
      }
    }
  }

  // MARK: - Command Center

  private var commandCenter: some View {
    let isPolling = mission.orchestratorStatus == "polling"
    let isIdle = mission.orchestratorStatus == "idle" || mission.orchestratorStatus == nil
    let canStart = mission.enabled && !mission.paused && isIdle
    let canPause = mission.enabled && isPolling && !mission.paused
    let canResume = mission.enabled && mission.paused

    return VStack(alignment: .leading, spacing: 0) {
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
            await startOrchestrator()
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
        telemetryChip(icon: "bolt.fill", count: mission.activeCount, color: .statusWorking, label: "active")
        telemetryChip(icon: "clock.fill", count: mission.queuedCount, color: .feedbackCaution, label: "queued")
        telemetryChip(icon: "checkmark.circle.fill", count: mission.completedCount, color: .feedbackPositive, label: "done")
        telemetryChip(icon: "xmark.circle.fill", count: mission.failedCount, color: .feedbackNegative, label: "failed")
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
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
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
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.surfaceBorder, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
  }

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

  // Segmented progress bar showing pipeline proportions
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

  private func telemetryChip(icon: String, count: UInt32, color: Color, label: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(count > 0 ? color : Color.textQuaternary)

      Text("\(count)")
        .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
        .foregroundStyle(count > 0 ? color : Color.textQuaternary)

      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
    }
  }

  // Compact config context — replaces the full Orchestrator + Filters cards
  private func configContextRows(_ settings: MissionSettings) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      // Row 1: Trigger + Agents + Retries
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

      // Row 2: Filters (only if any configured)
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

  // MARK: - Active Threads

  private var activeThreadsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader(
        title: "Active Threads",
        icon: "bolt.fill",
        color: Color.statusWorking,
        trailing: settings.map { "\(runningIssues.count) of \($0.provider.maxConcurrent)" }
      )

      let layout = isCompact
        ? AnyLayout(VStackLayout(spacing: Spacing.sm))
        : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.sm))

      layout {
        ForEach(runningIssues) { issue in
          agentCard(issue)
        }
      }
    }
  }

  private func agentCard(_ issue: MissionIssueItem) -> some View {
    let session = issue.sessionId.flatMap { sessionStore?.session($0) }
    let hasSessionData = session?.model != nil
    let sessionStatus = hasSessionData ? session?.displayStatus : nil
    let cardAccent: Color = sessionStatus?.color ?? Color.statusWorking
    let providerColor: Color = issue.provider == "codex" ? Color.feedbackPositive : Color.accent

    return VStack(alignment: .leading, spacing: Spacing.sm) {
      // Header: identifier + provider badge
      HStack(spacing: Spacing.sm_) {
        Circle()
          .fill(cardAccent)
          .frame(width: 6, height: 6)

        Text(issue.identifier)
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.accent)

        Spacer()

        Text(issue.provider.capitalized)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(providerColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 2)
          .background(
            providerColor.opacity(OpacityTier.subtle),
            in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          )
      }

      // Title
      Text(issue.title)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(2)

      // Tracker state + attempt
      HStack(spacing: Spacing.sm_) {
        Text(issue.trackerState)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .padding(.horizontal, Spacing.xs)
          .padding(.vertical, 1)
          .background(
            Color.backgroundTertiary,
            in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          )

        if issue.attempt > 1 {
          Text("attempt #\(issue.attempt)")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.feedbackCaution)
        }

        Spacer()
      }

      // ── Actions ──────────────────────────────────────────
      Divider().foregroundStyle(Color.surfaceBorder)

      HStack(spacing: Spacing.sm) {
        Button {
          Task { await retryIssue(issue) }
        } label: {
          HStack(spacing: Spacing.xxs) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 9, weight: .bold))
            Text("Restart")
              .font(.system(size: TypeScale.micro, weight: .medium))
          }
          .foregroundStyle(Color.feedbackCaution)
        }
        .buttonStyle(.plain)

        Spacer()

        // ── Session Preview ──────────────────────────────────
        if let session, hasSessionData {
          sessionPreview(session)
        } else if issue.sessionId != nil {
          HStack(spacing: Spacing.xxs) {
            Text("Session")
              .font(.system(size: TypeScale.micro, weight: .medium))
            Image(systemName: "arrow.right")
              .font(.system(size: 8, weight: .bold))
          }
          .foregroundStyle(Color.accent)
        }
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(cardAccent.opacity(OpacityTier.light), lineWidth: 1)
        )
    )
    .shadow(color: cardAccent.opacity(OpacityTier.subtle), radius: 8, y: 2)
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

  // MARK: - Session Preview

  private func sessionPreview(_ session: SessionObservable) -> some View {
    let status = session.displayStatus

    return VStack(alignment: .leading, spacing: Spacing.sm_) {
      // Row 1: Status badge + Branch + Model
      HStack(spacing: Spacing.sm) {
        SessionStatusBadge(status: status, showIcon: true, size: .compact)

        if let branch = session.branch {
          HStack(spacing: Spacing.xxs) {
            Image(systemName: "arrow.triangle.branch")
              .font(.system(size: 8, weight: .medium))
            Text(branch.count > 20 ? String(branch.prefix(18)) + "\u{2026}" : branch)
          }
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }

      // Row 2: Tool activity + Tokens
      HStack(spacing: Spacing.sm) {
        if status == .permission, let tool = session.pendingToolName {
          // Permission needed — urgent
          HStack(spacing: Spacing.xs) {
            Image(systemName: "lock.fill")
              .font(.system(size: 8, weight: .bold))
            Text(tool)
              .lineLimit(1)
          }
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(status.color)
        } else if status == .question {
          // Question asked — urgent
          HStack(spacing: Spacing.xs) {
            Image(systemName: "questionmark.bubble")
              .font(.system(size: 8, weight: .bold))
            Text(session.pendingQuestion.map { String($0.prefix(50)) } ?? "Question")
              .lineLimit(1)
          }
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(status.color)
        } else if let tool = session.lastTool {
          // Active tool
          HStack(spacing: Spacing.xs) {
            Image(systemName: "wrench.fill")
              .font(.system(size: 8, weight: .medium))
            Text(tool)
              .lineLimit(1)
          }
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        if session.totalTokens > 0 {
          Text(formatTokenCount(session.totalTokens))
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
  }

  private func formatTokenCount(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
      return String(format: "%.1fM tok", Double(tokens) / 1_000_000)
    } else if tokens >= 1_000 {
      return String(format: "%.1fk tok", Double(tokens) / 1_000)
    }
    return "\(tokens) tok"
  }

  // MARK: - Attention Section

  private var attentionSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader(
        title: "Needs Attention",
        icon: "exclamationmark.triangle.fill",
        color: Color.feedbackNegative,
        count: failedIssues.count
      )

      ForEach(failedIssues) { issue in
        issueRow(issue, accent: Color.feedbackNegative)
      }
    }
  }

  // MARK: - Queue Section

  private var queueSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader(
        title: "Queued",
        icon: "clock.fill",
        color: Color.feedbackCaution,
        count: queuedIssues.count
      )

      ForEach(queuedIssues) { issue in
        issueRow(issue, accent: Color.feedbackCaution)
      }
    }
  }

  // MARK: - Completed Section

  private var completedSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionHeader(
        title: "Completed",
        icon: "checkmark.circle.fill",
        color: Color.feedbackPositive,
        count: completedIssues.count
      )

      ForEach(Array(completedIssues.prefix(5))) { issue in
        issueRow(issue, accent: Color.feedbackPositive)
      }

      if completedIssues.count > 5 {
        Button {
          onSelectTab(.issues)
        } label: {
          HStack(spacing: Spacing.xs) {
            Text("View all \(completedIssues.count) completed")
              .font(.system(size: TypeScale.micro, weight: .medium))
            Image(systemName: "arrow.right")
              .font(.system(size: 8, weight: .bold))
          }
          .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
        .padding(.leading, Spacing.lg)
      }
    }
  }

  // MARK: - Shared Components

  private func sectionHeader(
    title: String,
    icon: String,
    color: Color,
    count: Int? = nil,
    trailing: String? = nil
  ) -> some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(color)

      Text(title)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      if let count {
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

      Spacer()

      if let trailing {
        Text(trailing)
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  private func issueRow(_ issue: MissionIssueItem, accent: Color) -> some View {
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

          Text(issue.provider.capitalized)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          Text(issue.trackerState)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(
              Color.backgroundTertiary,
              in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            )

          if issue.orchestrationState != .queued {
            Button {
              Task { await retryIssue(issue) }
            } label: {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
            .help(issue.orchestrationState == .failed ? "Retry" : "Restart")
          }

          if issue.sessionId != nil {
            Image(systemName: "arrow.right.circle")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(Color.accent)
          }
        }

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
        Circle()
          .strokeBorder(
            (isPolling ? Color.accent : Color.textQuaternary).opacity(OpacityTier.subtle),
            lineWidth: 2
          )
          .frame(width: 56, height: 56)

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
        "Resume the orchestrator to continue processing issues."
      case "disabled":
        "Enable the mission to start processing issues."
      case "idle":
        "Configuration looks good. Start the orchestrator to begin polling for issues."
      default:
        "Start the orchestrator to begin polling for issues."
    }
  }

  // MARK: - Unified Setup (WORKFLOW.md exists)

  @State private var isScaffoldingFresh = false

  private var missionSetupWithMigration: some View {
    VStack(alignment: .leading, spacing: 0) {
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

  // MARK: - Workflow Migration Banner

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

  // MARK: - Networking

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

  // MARK: - Issue Actions

  private func retryIssue(_ issue: MissionIssueItem) async {
    guard let http else { return }
    do {
      let _: MissionOkResponse = try await http.request(
        path: "/api/missions/\(missionId)/issues/\(issue.issueId)/retry",
        method: "POST"
      )
      await onRefresh()
    } catch {
      print("[OrbitDock] Failed to retry issue: \(error)")
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
    if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
    return "\(Int(elapsed / 3600))h ago"
  }
}
