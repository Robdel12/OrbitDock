import SwiftUI

/// Harbor View — the fleet command center.
/// Project-grouped session display with promoted attention zone.
/// Mobile-first: designed for 375pt iPhone, scales up to desktop.
struct OverviewPanel: View {
  let viewModel: DashboardViewModel

  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(UsageServiceRegistry.self) private var usageRegistry
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var collapsedGroups: Set<String> = []

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var conversations: [DashboardConversationRecord] {
    viewModel.presentation?.filteredConversations ?? []
  }

  private var groups: [ConversationProjectGroup] {
    viewModel.presentation?.groups ?? []
  }

  private var attentionSessions: [DashboardConversationRecord] {
    conversations.filter(\.displayStatus.needsAttention)
  }

  var body: some View {
    if viewModel.isLoading {
      loadingState
    } else if conversations.isEmpty {
      emptyState
    } else {
      overviewContent
    }
  }

  // MARK: - Overview Content

  private var overviewContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.xl) {
        usageLimitsSection

        if !attentionSessions.isEmpty {
          attentionZone
        }

        projectGroupList
      }
      .padding(layoutMode.isPhoneCompact ? Spacing.lg : Spacing.section)
    }
    .scrollContentBackground(.hidden)
    .task {
      await usageRegistry.refreshAll()
    }
  }

  // MARK: - Fleet Telemetry (Usage + Today Stats)

  private var activeProviders: [(provider: Provider, windows: [RateLimitWindow], isLoading: Bool)] {
    usageRegistry.allProviders.compactMap { provider in
      let windows = usageRegistry.windows(for: provider)
      let isLoading = usageRegistry.isLoading(for: provider)
      guard !windows.isEmpty || isLoading else { return nil }
      return (provider: provider, windows: windows, isLoading: isLoading)
    }
  }

  @ViewBuilder
  private var usageLimitsSection: some View {
    let providers = activeProviders
    let todayStats = usageRegistry.summary?.today

    if !providers.isEmpty || todayStats != nil {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Today strip — cost · sessions · tokens
        if let stats = todayStats {
          todayStatsStrip(stats)
        }

        // Provider limits — side by side on desktop, stacked on phone
        if !providers.isEmpty {
          if layoutMode.isPhoneCompact || providers.count == 1 {
            ForEach(Array(providers.enumerated()), id: \.element.provider.id) { _, entry in
              providerLimitsCard(entry.provider, windows: entry.windows, isLoading: entry.isLoading)
            }
          } else {
            HStack(spacing: Spacing.sm) {
              ForEach(Array(providers.enumerated()), id: \.element.provider.id) { _, entry in
                providerLimitsCard(entry.provider, windows: entry.windows, isLoading: entry.isLoading)
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Today Stats Strip

  private func todayStatsStrip(_ stats: ServerUsageSummaryBucketPayload) -> some View {
    HStack(spacing: Spacing.lg) {
      telemetryMetric(
        value: DashboardFormatters.costCompact(stats.totalCostUSD),
        label: "cost",
        emphasize: stats.totalCostUSD > 0
      )

      telemetryMetric(
        value: "\(stats.sessionCount)",
        label: stats.sessionCount == 1 ? "session" : "sessions"
      )

      telemetryMetric(
        value: DashboardFormatters.tokens(Int(stats.totalTokens), zeroDisplay: "0"),
        label: "tokens"
      )

      Spacer(minLength: 0)

      Text("Today")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    )
  }

  private func telemetryMetric(value: String, label: String, emphasize: Bool = false) -> some View {
    HStack(spacing: Spacing.xxs) {
      Text(value)
        .font(.system(size: TypeScale.caption, weight: emphasize ? .bold : .semibold, design: .monospaced))
        .foregroundStyle(emphasize ? Color.textPrimary : Color.textSecondary)
        .contentTransition(.numericText())

      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }

  // MARK: - Provider Limits Card

  private func providerLimitsCard(_ provider: Provider, windows: [RateLimitWindow], isLoading: Bool) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      // Provider header — icon + name + plan, all compact
      HStack(spacing: Spacing.xs) {
        Image(systemName: provider.icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(provider.accentColor)

        Text(provider.displayName)
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(Color.textSecondary)

        if let plan = usageRegistry.planName(for: provider) {
          Text(plan)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      if !windows.isEmpty {
        VStack(spacing: Spacing.xs) {
          ForEach(windows) { window in
            compactWindowRow(window, provider: provider)
          }
        }
      } else if isLoading {
        HStack(spacing: Spacing.sm) {
          ProgressView().controlSize(.mini)
          Text("Loading...")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
    .padding(Spacing.md_)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    )
  }

  private func compactWindowRow(_ window: RateLimitWindow, provider: Provider) -> some View {
    let usageColor = provider.color(for: window.utilization)
    let showProjection = window.projectedAtReset > window.utilization + 5

    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: Spacing.xs) {
        Text(window.descriptiveLabel)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)

        if window.willExceed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 7))
            .foregroundStyle(Color.feedbackCaution)
        }

        Spacer(minLength: 0)

        Text("\(Int(window.utilization))%")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(usageColor)

        if showProjection {
          Text("→ \(Int(window.projectedAtReset.rounded()))%")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(DashboardFormatters.projectedColor(window.projectedAtReset))
        }
      }

      UsageGaugeBar(
        utilization: window.utilization,
        usageColor: usageColor,
        projectedAtReset: window.projectedAtReset,
        showProjection: showProjection
      )
      .frame(height: 3)
    }
  }

  // MARK: - Attention Zone

  private var attentionZone: some View {
    let columns: [GridItem] = layoutMode.isPhoneCompact
      ? [GridItem(.flexible())]
      : [GridItem(.flexible(), spacing: Spacing.md), GridItem(.flexible(), spacing: Spacing.md)]

    return VStack(alignment: .leading, spacing: Spacing.md) {
      SectorHeader(title: "Incoming", color: .statusPermission, count: attentionSessions.count)

      LazyVGrid(columns: columns, spacing: Spacing.md) {
        ForEach(attentionSessions) { session in
          TransmissionCard(session: session) {
            router.selectSession(session.sessionRef, source: .dashboardStream)
          }
          .contextMenu {
            Button {
              _ = Platform.services.revealInFileBrowser(session.projectPath)
            } label: {
              Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
              let command = "claude --resume \(session.sessionId)"
              Platform.services.copyToClipboard(command)
            } label: {
              Label("Copy Resume Command", systemImage: "doc.on.doc")
            }

            if session.canEnd {
              Divider()
              Button(role: .destructive) {
                Task { await endSession(session) }
              } label: {
                Label("End Session", systemImage: "stop.circle")
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Project Group List

  private var projectGroupList: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      ForEach(groups) { group in
        let nonAttentionSessions = group.sortedConversations.filter {
          !$0.displayStatus.needsAttention
        }

        if !nonAttentionSessions.isEmpty {
          projectGroupSection(group: group, sessions: nonAttentionSessions)
        }
      }
    }
  }

  private func projectGroupSection(
    group: ConversationProjectGroup,
    sessions: [DashboardConversationRecord]
  ) -> some View {
    let isCollapsed = collapsedGroups.contains(group.id)
    return VStack(alignment: .leading, spacing: 0) {
      SectorHeader(
        title: group.name,
        color: group.signalColor,
        count: sessions.count,
        isCollapsed: isCollapsed
      ) {
        withAnimation(Motion.hover) {
          if isCollapsed {
            collapsedGroups.remove(group.id)
          } else {
            collapsedGroups.insert(group.id)
          }
        }
      }

      // Signal strip — project health at a glance when collapsed
      if isCollapsed {
        HStack(spacing: 2) {
          ForEach(sessions) { session in
            Circle()
              .fill(session.displayStatus.color)
              .frame(width: 4, height: 4)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.bottom, Spacing.xs)
      }

      if !isCollapsed {
        VStack(spacing: 0) {
          ForEach(sessions) { session in
            overviewSessionRow(session)

            if session.id != sessions.last?.id {
              Rectangle()
                .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
                .frame(height: 1)
                .padding(.leading, Spacing.lg)
            }
          }
        }
        .background(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .fill(Color.backgroundSecondary)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
      }
    }
  }

  // MARK: - Overview Session Row

  private func overviewSessionRow(_ session: DashboardConversationRecord) -> some View {
    let status = session.displayStatus
    let isActive = status == .working || status.needsAttention

    return Button {
      router.selectSession(session.sessionRef, source: .dashboardStream)
    } label: {
      HStack(spacing: Spacing.sm) {
        OrbitalStatusIndicator(status: status, size: 12)

        VStack(alignment: .leading, spacing: 2) {
          // Line 1: title + recency
          HStack(spacing: Spacing.xs) {
            Text(session.title)
              .font(.system(size: TypeScale.caption, weight: isActive ? .bold : .semibold))
              .foregroundStyle(isActive ? Color.textPrimary : Color.textSecondary)
              .lineLimit(1)

            Spacer(minLength: Spacing.xs)

            if let recency = recencyLabel(for: session) {
              Text(recency)
                .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
            }
          }

          // Line 2: state-driven metadata
          overviewSessionMeta(session)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, layoutMode.isPhoneCompact ? Spacing.md_ : Spacing.sm)
      .frame(minHeight: layoutMode.isPhoneCompact ? 44 : 0)
      .opacity(status == .ended ? 0.55 : 1.0)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button {
        _ = Platform.services.revealInFileBrowser(session.projectPath)
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }

      Button {
        let command = "claude --resume \(session.sessionId)"
        Platform.services.copyToClipboard(command)
      } label: {
        Label("Copy Resume Command", systemImage: "doc.on.doc")
      }

      if session.canEnd {
        Divider()
        Button(role: .destructive) {
          Task { await endSession(session) }
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    }
  }

  @ViewBuilder
  private func overviewSessionMeta(_ session: DashboardConversationRecord) -> some View {
    ViewThatFits(in: .horizontal) {
      // Full: provider + model + activity/preview + branch
      HStack(spacing: Spacing.xs) {
        providerLabel(session)
        activityLabel(session)
        if let branch = session.compactBranchLabel {
          branchLabel(branch)
        }
      }
      // Compact: provider + model + activity
      HStack(spacing: Spacing.xs) {
        providerLabel(session)
        activityLabel(session)
      }
      // Minimal: provider + model only
      HStack(spacing: Spacing.xs) {
        providerLabel(session)
      }
    }
  }

  private func providerLabel(_ session: DashboardConversationRecord) -> some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: session.provider.icon)
        .font(.system(size: 7, weight: .semibold))
        .foregroundStyle(session.provider.accentColor.opacity(0.7))

      if let model = session.modelDisplayLabel {
        Text(model)
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }
    }
  }

  @ViewBuilder
  private func activityLabel(_ session: DashboardConversationRecord) -> some View {
    switch session.displayStatus {
    case .working:
      if let toolName = session.pendingToolName {
        Text(toolName)
          .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.statusWorking.opacity(0.8))
          .lineLimit(1)
      } else {
        Text("thinking\u{2026}")
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.statusWorking.opacity(0.7))
      }

    case .permission:
      Text(!session.alertContextText.isEmpty ? session.alertContextText : "awaiting approval")
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.statusPermission.opacity(0.8))
        .lineLimit(1)

    case .question:
      Text(!session.alertContextText.isEmpty ? session.alertContextText : "has a question")
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.statusQuestion.opacity(0.8))
        .lineLimit(1)

    case .reply:
      if let diff = session.diffPreview, diff.fileCount > 0 {
        overviewDiffStats(diff)
      } else {
        Text(session.compactPreviewText)
          .font(.system(size: TypeScale.mini, weight: .regular))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
      }

    case .ended:
      Text(session.compactPreviewText)
        .font(.system(size: TypeScale.mini, weight: .regular))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)
    }
  }

  private func overviewDiffStats(_ diff: ServerDashboardDiffPreview) -> some View {
    HStack(spacing: Spacing.xs) {
      Text("+\(diff.additions)")
        .foregroundStyle(Color.diffAddedAccent)
      Text("-\(diff.deletions)")
        .foregroundStyle(Color.diffRemovedAccent)
      Text("\(diff.fileCount) \(diff.fileCount == 1 ? "file" : "files")")
        .foregroundStyle(Color.textQuaternary)
    }
    .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
  }

  private func branchLabel(_ branch: String) -> some View {
    Text(branch)
      .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.gitBranch.opacity(0.5))
      .lineLimit(1)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    let copy = emptyStateCopy

    return VStack(spacing: Spacing.lg) {
      Spacer()

      ZStack {
        Circle()
          .strokeBorder(Color.accent.opacity(0.15), lineWidth: 1.5)
          .frame(width: 64, height: 64)
          .shadow(color: Color.accent.opacity(0.08), radius: 20)

        Image(systemName: "terminal")
          .font(.system(size: 28, weight: .ultraLight))
          .foregroundStyle(Color.textQuaternary)
      }

      VStack(spacing: Spacing.sm) {
        Text(copy.title)
          .font(.system(size: TypeScale.title, weight: .bold))
          .foregroundStyle(Color.textPrimary)

        Text(copy.message)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 300)
      }

      Button {
        router.openNewSessionSheet()
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "plus")
            .font(.system(size: IconScale.md, weight: .semibold))
          Text("New Session")
            .font(.system(size: TypeScale.caption, weight: .semibold))
        }
        .foregroundStyle(Color.accent)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .fill(Color.accent.opacity(OpacityTier.light))
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(Color.accent.opacity(OpacityTier.subtle), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateCopy: (title: String, message: String) {
    let statuses = runtimeRegistry.runtimes
      .filter(\.endpoint.isEnabled)
      .map { runtimeRegistry.displayConnectionStatus(for: $0.endpoint.id) }

    if statuses.contains(where: { if case .connecting = $0 { return true }; return false }) {
      return ("Connecting to server", "Waiting for sessions to load...")
    }

    if statuses.contains(where: { if case .failed = $0 { return true }; if case .disconnected = $0 { return true }; return false }) {
      return ("Server unavailable", "Check Server Settings, then try reconnecting.")
    }

    return ("All clear", "No active sessions. Start a new one to get going.")
  }

  // MARK: - Loading State

  private var loadingState: some View {
    VStack(spacing: Spacing.md) {
      Circle()
        .strokeBorder(Color.accent.opacity(0.25), lineWidth: 1.5)
        .frame(width: 36, height: 36)
        .shadow(color: Color.accent.opacity(0.10), radius: 12)

      Text("Scanning for sessions...")
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Helpers

  private func endSession(_ session: DashboardConversationRecord) async {
    let store = runtimeRegistry.sessionStore(
      for: session.sessionRef.endpointId,
      fallback: runtimeRegistry.activeSessionStore
    )
    try? await store.endSession(session.sessionId)
    await runtimeRegistry.refreshDashboardConversations()
  }

  private func recencyLabel(for session: DashboardConversationRecord) -> String? {
    guard let date = session.lastActivityAt ?? session.startedAt else { return nil }
    let interval = max(0, Date.now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }
}
