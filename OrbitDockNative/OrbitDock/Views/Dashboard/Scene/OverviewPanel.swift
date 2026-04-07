import SwiftUI

/// Harbor View — the fleet command center.
/// Project-grouped session display with promoted attention zone.
/// Mobile-first: designed for 375pt iPhone, scales up to desktop.
struct OverviewPanel: View {
  let viewModel: DashboardViewModel

  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
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

  private var triageCounts: (attention: Int, orbit: Int, ready: Int) {
    let attn = conversations.filter(\.displayStatus.needsAttention).count
    let orbit = conversations.filter { $0.displayStatus == .working }.count
    let ready = conversations.filter { $0.displayStatus == .reply || $0.displayStatus == .ended }.count
    return (attn, orbit, ready)
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
        fleetStatusStrip

        if !attentionSessions.isEmpty {
          attentionZone
        }

        projectGroupList
      }
      .padding(layoutMode.isPhoneCompact ? Spacing.lg : Spacing.section)
    }
    .scrollContentBackground(.hidden)
  }

  // MARK: - Fleet Status Strip

  private var fleetStatusStrip: some View {
    let counts = triageCounts
    var pills: [(icon: String, count: Int, label: String, color: Color)] = []

    if counts.attention > 0 {
      pills.append(("exclamationmark.triangle.fill", counts.attention, "attention", .statusPermission))
    }
    if counts.orbit > 0 {
      pills.append(("bolt.fill", counts.orbit, "in orbit", .statusWorking))
    }
    pills.append(("bubble.left.fill", counts.ready, "docked", .statusReply))

    return HStack(spacing: 0) {
      HStack(spacing: Spacing.sm_) {
        ForEach(Array(pills.enumerated()), id: \.offset) { index, pill in
          if index > 0 {
            Text("·")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }
          statusPill(icon: pill.icon, count: pill.count, label: pill.label, color: pill.color)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm_)
      .background(
        Capsule(style: .continuous)
          .fill(Color.backgroundSecondary)
      )
      .overlay(
        Capsule(style: .continuous)
          .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
      )

      Spacer()
    }
  }

  private func statusPill(icon: String, count: Int, label: String, color: Color) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(color)

      Text("\(count)")
        .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
        .foregroundStyle(count > 0 ? Color.textPrimary : Color.textQuaternary)

      Text(label)
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }

  // MARK: - Attention Zone

  private var attentionZone: some View {
    let columns: [GridItem] = layoutMode.isPhoneCompact
      ? [GridItem(.flexible())]
      : [GridItem(.flexible(), spacing: Spacing.md), GridItem(.flexible(), spacing: Spacing.md)]

    return VStack(alignment: .leading, spacing: Spacing.md) {
      zoneHeader(
        title: "Needs Attention",
        icon: "exclamationmark.triangle.fill",
        color: .statusPermission,
        count: attentionSessions.count
      )

      LazyVGrid(columns: columns, spacing: Spacing.md) {
        ForEach(attentionSessions) { session in
          attentionCard(session)
        }
      }
    }
  }

  private func attentionCard(_ session: DashboardConversationRecord) -> some View {
    let statusColor = session.displayStatus.color

    return Button {
      router.selectSession(session.sessionRef, source: .dashboardStream)
    } label: {
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Header: status dot + title + status badge
        HStack(spacing: Spacing.sm) {
          Image(systemName: session.displayStatus.icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(statusColor)

          Text(session.title)
            .font(.system(size: TypeScale.subhead, weight: .bold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(2)

          Spacer(minLength: Spacing.sm)

          HStack(spacing: Spacing.gap) {
            Text(session.displayStatus.label)
              .font(.system(size: TypeScale.micro, weight: .bold))
          }
          .foregroundStyle(statusColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(
            Capsule(style: .continuous)
              .fill(statusColor.opacity(OpacityTier.light))
          )
        }

        // The actual permission/question text
        Text(session.alertContextText)
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)

        // Footer: provider + model + branch + time
        HStack(spacing: Spacing.sm_) {
          Image(systemName: session.provider.icon)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(session.provider.accentColor.opacity(0.7))

          if let model = session.modelDisplayLabel {
            Text(model)
              .font(.system(size: TypeScale.mini, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }

          Spacer()

          if let branch = session.compactBranchLabel {
            Text(branch)
              .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.gitBranch.opacity(0.5))
              .lineLimit(1)
          }

          if let recency = recencyLabel(for: session) {
            Text(recency)
              .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }
        }
      }
      .padding(Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                statusColor.opacity(OpacityTier.tint),
                Color.backgroundSecondary,
              ],
              startPoint: .leading,
              endPoint: UnitPoint(x: 0.3, y: 0.5)
            )
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .strokeBorder(
            LinearGradient(
              colors: [
                statusColor.opacity(OpacityTier.medium),
                statusColor.opacity(OpacityTier.subtle),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      .shadow(color: statusColor.opacity(0.20), radius: 16, y: 0)
      .shadow(color: statusColor.opacity(0.08), radius: 4, y: 0)
    }
    .buttonStyle(.plain)
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
      // Group header — manifest-style
      Button {
        withAnimation(Motion.hover) {
          if isCollapsed {
            collapsedGroups.remove(group.id)
          } else {
            collapsedGroups.insert(group.id)
          }
        }
      } label: {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "folder.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(group.signalColor.opacity(0.7))

          Text(group.name.uppercased())
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(Color.textSecondary)
            .tracking(0.8)
            .lineLimit(1)

          Spacer()

          if group.attentionCount > 0 {
            HStack(spacing: Spacing.gap) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 7, weight: .bold))
              Text("\(group.attentionCount)")
                .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(Color.statusPermission)
          }

          Text("\(sessions.count)")
            .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)

          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .frame(width: 10)
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Session rows with left accent edge
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
      VStack(alignment: .leading, spacing: 2) {
        // Line 1: title + optional status tag + recency
        HStack(spacing: Spacing.xs) {
          Text(session.title)
            .font(.system(size: TypeScale.caption, weight: isActive ? .bold : .semibold))
            .foregroundStyle(isActive ? Color.textPrimary : Color.textSecondary)
            .lineLimit(1)

          if isActive {
            inlineStatusTag(status)
          }

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
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, layoutMode.isPhoneCompact ? Spacing.md_ : Spacing.sm)
      .frame(minHeight: layoutMode.isPhoneCompact ? 44 : 0)
      .opacity(status == .ended ? 0.55 : 1.0)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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

  private func activityLabel(_ session: DashboardConversationRecord) -> some View {
    Group {
      if session.displayStatus == .working, let toolName = session.pendingToolName {
        HStack(spacing: Spacing.gap) {
          Image(systemName: "gearshape.fill")
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(Color.statusWorking.opacity(0.6))
          Text(toolName)
            .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.statusWorking.opacity(0.7))
            .lineLimit(1)
        }
      } else if session.displayStatus == .permission, let toolName = session.pendingToolName {
        Text(toolName)
          .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.statusPermission.opacity(0.7))
          .lineLimit(1)
      } else if session.displayStatus == .question, !session.alertContextText.isEmpty {
        Text(session.alertContextText)
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.statusQuestion.opacity(0.7))
          .lineLimit(1)
      } else {
        Text(session.compactPreviewText)
          .font(.system(size: TypeScale.mini, weight: .regular))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
      }
    }
  }

  private func branchLabel(_ branch: String) -> some View {
    Text(branch)
      .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.gitBranch.opacity(0.5))
      .lineLimit(1)
  }

  private func inlineStatusTag(_ status: SessionDisplayStatus) -> some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: status.icon)
        .font(.system(size: 7, weight: .bold))
      Text(status.label)
        .font(.system(size: TypeScale.mini, weight: .bold))
    }
    .foregroundStyle(status.color)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, 1)
    .background(status.color.opacity(OpacityTier.light), in: Capsule())
  }

  // MARK: - Zone Header

  private func zoneHeader(title: String, icon: String, color: Color, count: Int) -> some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: icon)
        .font(.system(size: IconScale.sm, weight: .semibold))
        .foregroundStyle(color)

      Text(title.uppercased())
        .font(.system(size: TypeScale.micro, weight: .bold))
        .foregroundStyle(color.opacity(0.8))
        .tracking(0.8)

      Text("\(count)")
        .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
        .foregroundStyle(color.opacity(0.7))

      Spacer()
    }
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
          .foregroundStyle(
            LinearGradient(
              colors: [Color.accent.opacity(0.4), Color.textQuaternary],
              startPoint: .top,
              endPoint: .bottom
            )
          )
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

  private func recencyLabel(for session: DashboardConversationRecord) -> String? {
    guard let date = session.lastActivityAt ?? session.startedAt else { return nil }
    let interval = max(0, Date.now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }
}
