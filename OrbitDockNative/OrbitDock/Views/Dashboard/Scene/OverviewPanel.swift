import SwiftUI

/// Harbor View — the fleet command center.
/// Project-grouped session display with promoted attention zone.
/// Mobile-first: designed for 375pt iPhone, scales up to desktop.
struct OverviewPanel: View {
  let viewModel: DashboardViewModel

  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(DashboardDataService.self) private var dashboardDataService
  @Environment(UsageServiceRegistry.self) private var usageRegistry
  @Environment(\.rootSessionActions) private var rootSessionActions
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var collapsedGroups: Set<String> = []

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var usageRefreshIdentity: String {
    let todayStartUnix = UInt64(max(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, 0))
    return "\(todayStartUnix)|\(runtimeRegistry.dashboardRefreshIdentity)"
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

  private var usageEntries: [OverviewUsageProviderEntry] {
    usageRegistry.allProviders.compactMap { provider in
      let windows = usageRegistry.windows(for: provider)
      let isLoading = usageRegistry.isLoading(for: provider)
      guard !windows.isEmpty || isLoading else { return nil }
      return OverviewUsageProviderEntry(
        provider: provider,
        planName: usageRegistry.planName(for: provider),
        windows: windows,
        isLoading: isLoading
      )
    }
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

  private var overviewContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.xl) {
        OverviewUsageSection(
          entries: usageEntries,
          todayStats: usageRegistry.summary?.today,
          layoutMode: layoutMode
        )

        if !attentionSessions.isEmpty {
          OverviewAttentionZone(
            sessions: attentionSessions,
            layoutMode: layoutMode,
            onSelect: openSession,
            onEnd: endSession
          )
        }

        VStack(alignment: .leading, spacing: Spacing.lg) {
          ForEach(groups) { group in
            let sessions = group.sortedConversations.filter {
              !$0.displayStatus.needsAttention
            }

            if !sessions.isEmpty {
              OverviewProjectGroupSection(
                group: group,
                sessions: sessions,
                isCollapsed: collapsedBinding(for: group.id),
                layoutMode: layoutMode,
                onSelect: openSession,
                onEnd: endSession
              )
            }
          }
        }
      }
      .padding(layoutMode.isPhoneCompact ? Spacing.lg : Spacing.section)
    }
    .scrollContentBackground(.hidden)
    .task(id: usageRefreshIdentity) {
      await usageRegistry.refreshIfNeeded()
    }
  }

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

    if statuses.contains(where: {
      if case .failed = $0 { return true }
      if case .disconnected = $0 { return true }
      return false
    }) {
      return ("Server unavailable", "Check Server Settings, then try reconnecting.")
    }

    return ("All clear", "No active sessions. Start a new one to get going.")
  }

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

  private func collapsedBinding(for groupID: String) -> Binding<Bool> {
    Binding(
      get: { collapsedGroups.contains(groupID) },
      set: { isCollapsed in
        if isCollapsed {
          collapsedGroups.insert(groupID)
        } else {
          collapsedGroups.remove(groupID)
        }
      }
    )
  }

  private func openSession(_ session: DashboardConversationRecord) {
    router.selectSession(session.sessionRef, source: .dashboardStream)
  }

  private func endSession(_ session: DashboardConversationRecord) async {
    try? await rootSessionActions.endSession(session.sessionRef)
    await dashboardDataService.refreshNow()
  }
}
