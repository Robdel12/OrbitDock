import SwiftUI

struct SessionSidebar: View {
  let viewModel: DashboardViewModel
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var isAttentionExpanded = true
  @State private var isOrbitExpanded = true
  @State private var isDockedExpanded = true
  @State private var isCompletedExpanded = false

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var conversations: [DashboardConversationRecord] {
    viewModel.presentation?.sidebarConversations ?? []
  }

  private var attentionSessions: [DashboardConversationRecord] {
    conversations.filter(\.displayStatus.needsAttention)
  }

  private var orbitSessions: [DashboardConversationRecord] {
    conversations.filter { $0.displayStatus == .working }
  }

  private var dockedSessions: [DashboardConversationRecord] {
    conversations.filter { $0.displayStatus == .reply }
  }

  private var completedSessions: [DashboardConversationRecord] {
    conversations.filter { $0.displayStatus == .ended }
  }

  /// Server health — only shown when degraded or offline.
  private var serverStatusColor: Color? {
    let enabledRuntimes = runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
    guard !enabledRuntimes.isEmpty else { return nil }

    let statuses = enabledRuntimes.map { runtimeRegistry.displayConnectionStatus(for: $0.endpoint.id) }
    let hasFailed = statuses.contains { if case .failed = $0 { return true }; if case .disconnected = $0 { return true }; return false }
    let hasConnecting = statuses.contains { if case .connecting = $0 { return true }; return false }
    let allConnected = statuses.allSatisfy { if case .connected = $0 { return true }; return false }

    if hasFailed { return .statusPermission }
    if hasConnecting { return .statusQuestion }
    if allConnected { return nil } // All good — hide indicator
    return nil
  }

  var body: some View {
    VStack(spacing: 0) {
      sidebarHeader

      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.sm_) {
          if !attentionSessions.isEmpty {
            tierSection(
              title: "Attention",
              color: .statusPermission,
              sessions: attentionSessions,
              isExpanded: $isAttentionExpanded,
              forceExpanded: true
            )
          }

          if !orbitSessions.isEmpty {
            tierSection(
              title: "In Orbit",
              color: .statusWorking,
              sessions: orbitSessions,
              isExpanded: $isOrbitExpanded
            )
          }

          if !dockedSessions.isEmpty {
            tierSection(
              title: "Docked",
              color: .statusReply,
              sessions: dockedSessions,
              isExpanded: $isDockedExpanded
            )
          }

          if !completedSessions.isEmpty {
            tierSection(
              title: "Completed",
              color: .textQuaternary,
              sessions: completedSessions,
              isExpanded: $isCompletedExpanded
            )
          }

          if conversations.isEmpty && !viewModel.isLoading {
            noSessionsPlaceholder
              .padding(.top, Spacing.xl)
          }
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.xs)
      }
      .scrollContentBackground(.hidden)

      sidebarFooter
    }
    .background(Color.backgroundSecondary.opacity(0.5))
    .navigationTitle("Sessions")
    .toolbarTitleDisplayMode(.inline)
  }

  // MARK: - Header (Signal Board)

  private var sidebarHeader: some View {
    HStack(spacing: Spacing.md) {
      if attentionSessions.count > 0 {
        signalFilter(.attention, count: attentionSessions.count, color: .statusPermission, label: "incoming")
      }

      signalFilter(.running, count: orbitSessions.count, color: .statusWorking, label: "orbit")
      signalFilter(.ready, count: dockedSessions.count, color: .statusReply, label: "docked")

      Spacer(minLength: 0)

      if let statusColor = serverStatusColor {
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)
          .shadow(color: statusColor.opacity(0.4), radius: 4)
      }

      if !layoutMode.isPhoneCompact {
        Button {
          router.toggleSidebar()
        } label: {
          Image(systemName: "sidebar.left")
            .font(.system(size: IconScale.lg, weight: .medium))
            .foregroundStyle(Color.textTertiary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle sidebar (\u{2318}\\)")
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
        .frame(height: 1)
    }
  }

  /// Signal filter — fleet count that doubles as a filter toggle.
  /// Tap to filter to this status. Tap again to show all.
  private func signalFilter(
    _ filter: ActiveSessionWorkbenchFilter,
    count: Int,
    color: Color,
    label: String
  ) -> some View {
    let isActive = viewModel.workbenchFilter == filter

    return Button {
      viewModel.workbenchFilter = viewModel.workbenchFilter == filter ? .all : filter
    } label: {
      HStack(spacing: Spacing.xs) {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)

        Text("\(count)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
          .foregroundStyle(isActive ? Color.textPrimary : Color.textTertiary)
          .contentTransition(.numericText())
          .animation(Motion.standard, value: count)

        Text(label)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(isActive ? color : Color.textQuaternary)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(isActive ? color.opacity(OpacityTier.light) : Color.clear)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Tier Section

  @ViewBuilder
  private func tierSection(
    title: String,
    color: Color,
    sessions: [DashboardConversationRecord],
    isExpanded: Binding<Bool>,
    forceExpanded: Bool = false
  ) -> some View {
    let expanded = forceExpanded || isExpanded.wrappedValue

    VStack(alignment: .leading, spacing: 0) {
      SectorHeader(
        title: title,
        color: color,
        count: sessions.count,
        isCollapsed: forceExpanded ? nil : !expanded
      ) {
        guard !forceExpanded else { return }
        withAnimation(Motion.hover) {
          isExpanded.wrappedValue.toggle()
        }
      }
      .padding(.horizontal, Spacing.xs)

      if expanded {
        ForEach(sessions) { session in
          let isSelected = router.workspaceSelection == .session(session.sessionRef)

          Button {
            withAnimation(Motion.hover) {
              router.selectSession(session.sessionRef, source: .dashboardSidebar)
            }
          } label: {
            SidebarSessionRow(session: session, isSelected: isSelected)
              .frame(minHeight: layoutMode.isPhoneCompact ? 44 : 0)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  // MARK: - Footer

  private var sidebarFooter: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
        .frame(height: 1)

      HStack(spacing: Spacing.sm) {
        // New session — primary action
        Button {
          router.openNewSessionSheet()
        } label: {
          Image(systemName: "plus")
            .font(.system(size: IconScale.md, weight: .semibold))
            .foregroundStyle(Color.accent)
            .frame(width: 36, height: 36)
            .background(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Color.accent.opacity(OpacityTier.subtle))
            )
            .shadow(color: Color.accent.opacity(0.10), radius: 6, y: 0)
        }
        .buttonStyle(.plain)
        .help("New session")

        Spacer()

        footerNavButton(
          icon: "square.grid.2x2",
          label: "Overview",
          isActive: router.workspaceSelection == .overview
        ) {
          router.goToDashboard(source: .dashboardSidebar)
        }

        footerNavButton(
          icon: "antenna.radiowaves.left.and.right",
          label: "Missions",
          isActive: router.workspaceSelection == .missions
        ) {
          router.selectDashboardTab(.missions, source: .dashboardSidebar)
        }

        footerNavButton(
          icon: "books.vertical",
          label: "Library",
          isActive: router.workspaceSelection == .library
        ) {
          router.goToLibrary()
        }

        footerNavButton(
          icon: "gearshape",
          label: "Settings",
          isActive: router.workspaceSelection == .settings
        ) {
          router.goToSettings(source: .dashboardSidebar)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.md_)
    }
  }

  private func footerNavButton(
    icon: String,
    label: String,
    isActive: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(spacing: Spacing.xxs) {
        Image(systemName: icon)
          .font(.system(size: IconScale.lg, weight: .medium))
          .foregroundStyle(isActive ? Color.accent : Color.textTertiary)

        Circle()
          .fill(isActive ? Color.accent : Color.clear)
          .frame(width: 4, height: 4)
      }
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
  }

  // MARK: - Empty State

  private var noSessionsPlaceholder: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "terminal")
        .font(.system(size: 20, weight: .light))
        .foregroundStyle(Color.textQuaternary)
      Text("No active sessions")
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
    .frame(maxWidth: .infinity)
  }
}
