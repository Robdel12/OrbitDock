import SwiftUI

struct SessionSidebar: View {
  let viewModel: DashboardViewModel
  @Environment(AppRouter.self) private var router
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var isAttentionExpanded = true
  @State private var isOrbitExpanded = true
  @State private var isReadyExpanded = true

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

  private var readySessions: [DashboardConversationRecord] {
    conversations.filter { $0.displayStatus == .reply || $0.displayStatus == .ended }
  }

  var body: some View {
    VStack(spacing: 0) {
      sidebarHeader

      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.sm_) {
          overviewButton

          if !attentionSessions.isEmpty {
            tierSection(
              title: "Attention",
              icon: "exclamationmark.triangle.fill",
              color: .statusPermission,
              sessions: attentionSessions,
              isExpanded: $isAttentionExpanded,
              forceExpanded: true
            )
          }

          if !orbitSessions.isEmpty {
            tierSection(
              title: "In Orbit",
              icon: "bolt.fill",
              color: .statusWorking,
              sessions: orbitSessions,
              isExpanded: $isOrbitExpanded
            )
          }

          if !readySessions.isEmpty {
            tierSection(
              title: "Ready",
              icon: "bubble.left.fill",
              color: .statusReply,
              sessions: readySessions,
              isExpanded: $isReadyExpanded
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

  // MARK: - Header

  private var sidebarHeader: some View {
    @Bindable var viewModel = viewModel

    return HStack(spacing: Spacing.xs) {
      filterChip("All", filter: .all)
      filterChip("Attn", filter: .attention, color: .statusPermission)
      filterChip("Running", filter: .running, color: .statusWorking)
      filterChip("Ready", filter: .ready, color: .statusReply)

      Spacer(minLength: 0)

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
        .help("Toggle sidebar (⌘\\)")
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

  private func filterChip(
    _ label: String,
    filter: ActiveSessionWorkbenchFilter,
    color: Color = .textSecondary
  ) -> some View {
    let isActive = viewModel.workbenchFilter == filter

    return Button {
      viewModel.workbenchFilter = filter
    } label: {
      Text(label)
        .font(.system(size: TypeScale.micro, weight: isActive ? .bold : .medium))
        .foregroundStyle(isActive ? Color.textPrimary : Color.textTertiary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(isActive ? color.opacity(OpacityTier.light) : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .strokeBorder(isActive ? color.opacity(OpacityTier.subtle) : Color.clear, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Overview Button

  private var overviewButton: some View {
    let isSelected = router.workspaceSelection == .overview
    let attnCount = attentionSessions.count
    let orbitCount = orbitSessions.count
    let readyCount = readySessions.count

    return Button {
      router.goToDashboard(source: .dashboardSidebar)
    } label: {
      VStack(alignment: .leading, spacing: Spacing.sm_) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "square.grid.2x2")
            .font(.system(size: IconScale.md, weight: .semibold))
            .foregroundStyle(isSelected ? Color.accent : Color.textTertiary)

          Text("Overview")
            .font(.system(size: TypeScale.caption, weight: isSelected ? .bold : .semibold))
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)

          Spacer()
        }

        // Inline triage pills — at-a-glance status counts
        if attnCount > 0 || orbitCount > 0 || readyCount > 0 {
          HStack(spacing: Spacing.xs) {
            if attnCount > 0 {
              triagePill(count: attnCount, color: .statusPermission, icon: "exclamationmark.triangle.fill")
            }
            if orbitCount > 0 {
              triagePill(count: orbitCount, color: .statusWorking, icon: "bolt.fill")
            }
            if readyCount > 0 {
              triagePill(count: readyCount, color: .statusReply, icon: "bubble.left.fill")
            }
          }
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(isSelected ? Color.surfaceSelected : Color.surfaceHover.opacity(0.5))
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .strokeBorder(
            isSelected ? Color.accent.opacity(OpacityTier.medium) : Color.clear,
            lineWidth: 1
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func triagePill(count: Int, color: Color, icon: String) -> some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: icon)
        .font(.system(size: 7, weight: .bold))
      Text("\(count)")
        .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
    }
    .foregroundStyle(color)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.xxs)
    .background(
      Capsule(style: .continuous)
        .fill(color.opacity(OpacityTier.subtle))
    )
  }

  // MARK: - Tier Section

  @ViewBuilder
  private func tierSection(
    title: String,
    icon: String,
    color: Color,
    sessions: [DashboardConversationRecord],
    isExpanded: Binding<Bool>,
    forceExpanded: Bool = false
  ) -> some View {
    let expanded = forceExpanded || isExpanded.wrappedValue

    VStack(alignment: .leading, spacing: 0) {
      // Section header with left accent bar
      Button {
        if !forceExpanded {
          withAnimation(Motion.hover) {
            isExpanded.wrappedValue.toggle()
          }
        }
      } label: {
        HStack(spacing: Spacing.sm_) {
          if !forceExpanded {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(Color.textQuaternary)
              .frame(width: 10)
          }

          Text(title.uppercased())
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(color.opacity(0.8))
            .tracking(0.8)

          Spacer()

          Text("\(sessions.count)")
            .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
            .foregroundStyle(color.opacity(0.7))
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(
              Capsule(style: .continuous)
                .fill(color.opacity(OpacityTier.tint))
            )
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Session rows
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
          HStack(spacing: Spacing.xs) {
            Image(systemName: "plus")
              .font(.system(size: IconScale.md, weight: .semibold))
            Text("New")
              .font(.system(size: TypeScale.caption, weight: .semibold))
          }
          .foregroundStyle(Color.accent)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(Color.accent.opacity(OpacityTier.subtle))
          )
          .shadow(color: Color.accent.opacity(0.10), radius: 6, y: 0)
        }
        .buttonStyle(.plain)

        Spacer()

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
        HStack(spacing: Spacing.xs) {
          Image(systemName: icon)
            .font(.system(size: IconScale.md, weight: .medium))
          Text(label)
            .font(.system(size: TypeScale.caption, weight: .medium))
        }
        .foregroundStyle(isActive ? Color.textPrimary : Color.textTertiary)

        // Active underline indicator
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .fill(isActive ? Color.accent : Color.clear)
          .frame(height: 2)
      }
      .frame(minHeight: layoutMode.isPhoneCompact ? 44 : 0)
    }
    .buttonStyle(.plain)
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
