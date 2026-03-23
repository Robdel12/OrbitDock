import SwiftUI

struct MissionShowView: View {
  let missionId: String
  let endpointId: UUID

  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  @State private var viewModel = MissionControlViewModel()

  private var isCompact: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  var body: some View {
    VStack(spacing: 0) {
      #if os(macOS)
        navigationBar
        Divider().foregroundStyle(Color.surfaceBorder)
      #endif

      Group {
        if viewModel.isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.error {
          ContentUnavailableView(
            "Failed to Load Mission",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
        } else if let summary = viewModel.summary {
          missionContent(summary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.backgroundPrimary)
    .task {
      viewModel.bind(missionId: missionId, endpointId: endpointId, runtimeRegistry: runtimeRegistry)
      await viewModel.refreshDetail()
    }
    .onChange(of: viewModel.liveState?.deltaRevision) { _, _ in
      viewModel.applyLiveDelta()
    }
    .onChange(of: viewModel.liveState?.heartbeatRevision) { _, _ in
      viewModel.applyLiveHeartbeat()
    }
    #if os(iOS)
    .navigationTitle(viewModel.summary?.name ?? "Mission")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if let summary = viewModel.summary {
          iOSActionsMenu(summary)
        }
      }
    }
    #endif
    .alert(
      "Error",
      isPresented: Binding(get: { viewModel.actionError != nil }, set: { if !$0 { viewModel.actionError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(viewModel.actionError ?? "")
    }
    .sheet(isPresented: $viewModel.showWorktreeCleanup) {
      MissionWorktreeCleanupSheet(
        worktrees: viewModel.missionWorktrees,
        isLoading: viewModel.isLoadingWorktrees,
        isCleaning: viewModel.isCleaningWorktrees,
        onCancel: { viewModel.showWorktreeCleanup = false },
        onConfirm: { ids in
          Task {
            await viewModel.cleanupWorktrees(ids: ids)
            if viewModel.missionWorktrees.isEmpty {
              viewModel.showWorktreeCleanup = false
            }
          }
        }
      )
    }
  }

  // MARK: - Navigation Bar

  #if os(macOS)
    private var navigationBar: some View {
      HStack(spacing: Spacing.md) {
        Button {
          router.selectDashboardTab(.missions)
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "chevron.left")
              .font(.system(size: 11, weight: .semibold))
            Text("Missions")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(Color.textSecondary)
        }
        .buttonStyle(.plain)

        Spacer()

        if let summary = viewModel.summary {
          missionActions(summary)
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
      .background(Color.backgroundSecondary)
    }
  #endif

  // MARK: - Content

  private func missionContent(_ mission: MissionSummary) -> some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xl) {
          missionHeader(mission)
          tabBar

          switch viewModel.selectedTab {
            case .overview:
              MissionOverviewTab(
                mission: mission,
                settings: viewModel.settings,
                issues: viewModel.issues,
                missionId: missionId,
                missionFileExists: viewModel.missionFileExists,
                workflowMigrationAvailable: viewModel.workflowMigrationAvailable,
                http: viewModel.http,
                isCompact: isCompact,
                endpointId: endpointId,
                dashboardConversationsBySessionId: viewModel.dashboardConversationsBySessionId,
                nextTickAt: viewModel.nextTickAt,
                lastTickAt: viewModel.lastTickAt,
                onRefresh: { await viewModel.refreshDetail() },
                onApplyDetail: { viewModel.applyDetail($0) },
                onSelectTab: { tab in
                  withAnimation(Motion.standard) { viewModel.selectedTab = tab }
                },
                onUpdateMission: { enabled, paused in
                  await viewModel.updateMission(enabled: enabled, paused: paused)
                },
                onNavigateToSession: { sessionId in
                  let ref = SessionRef(endpointId: endpointId, sessionId: sessionId)
                  router.selectSession(ref, source: .external)
                },
                onTransitionIssue: { issueId, target, reason in
                  await viewModel.transitionIssue(issueId: issueId, targetState: target, reason: reason)
                }
              )
            case .settings:
              MissionSettingsTab(
                settings: viewModel.settings,
                repoRoot: mission.repoRoot,
                missionId: missionId,
                trackerKind: mission.trackerKind,
                missionFileName: mission.resolvedFileName,
                http: viewModel.http,
                isCompact: isCompact,
                onUpdated: { await viewModel.refreshDetail() }
              )
            case .issues:
              MissionIssuesTab(
                issues: viewModel.issues,
                missionId: missionId,
                endpointId: endpointId,
                http: viewModel.http,
                isCompact: isCompact,
                onTransitionIssue: { issueId, target, reason in
                  await viewModel.transitionIssue(issueId: issueId, targetState: target, reason: reason)
                }
              )
          }
        }
        .padding(Spacing.section)
      }
    }
  }

  // MARK: - Tab Bar

  private var tabBar: some View {
    HStack(spacing: 0) {
      ForEach(MissionTab.allCases, id: \.self) { tab in
        let isSelected = viewModel.selectedTab == tab
        Button {
          withAnimation(Motion.standard) {
            viewModel.selectedTab = tab
          }
        } label: {
          VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm_) {
              Image(systemName: tab.icon)
                .font(.system(size: IconScale.sm, weight: .semibold))
              Text(tab.title)
                .font(.system(size: TypeScale.caption, weight: .semibold))
              if tab == .issues, !viewModel.issues.isEmpty {
                Text("\(viewModel.issues.count)")
                  .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
                  .foregroundStyle(isSelected ? Color.accent : Color.textQuaternary)
                  .padding(.horizontal, Spacing.xs)
                  .padding(.vertical, 1)
                  .background(
                    isSelected
                      ? Color.accent.opacity(OpacityTier.subtle)
                      : Color.backgroundTertiary,
                    in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                  )
              }
            }
            .foregroundStyle(isSelected ? Color.accent : Color.textTertiary)

            // Active indicator line
            RoundedRectangle(cornerRadius: 1, style: .continuous)
              .fill(isSelected ? Color.accent : .clear)
              .frame(height: 2)
          }
          .padding(.horizontal, Spacing.lg)
          .padding(.top, Spacing.sm)
        }
        .buttonStyle(.plain)
      }

      Spacer()
    }
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.medium))
        .frame(height: 1)
    }
  }

  // MARK: - Header

  private func missionHeader(_ mission: MissionSummary) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .center, spacing: Spacing.md) {
        // Status orb with animated rings
        ZStack {
          if mission.orchestratorStatus == "polling" {
            Circle()
              .stroke(mission.statusColor.opacity(OpacityTier.subtle), lineWidth: 1)
              .frame(width: 36, height: 36)

            Circle()
              .stroke(mission.statusColor.opacity(OpacityTier.light), lineWidth: 1)
              .frame(width: 28, height: 28)
              .animation(
                .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                value: mission.orchestratorStatus
              )
          }

          Circle()
            .fill(mission.statusColor.opacity(OpacityTier.medium))
            .frame(width: 20, height: 20)

          Circle()
            .fill(mission.statusColor)
            .frame(width: 8, height: 8)
        }
        .frame(width: 36, height: 36)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(mission.name)
            .font(.system(size: isCompact ? TypeScale.large : TypeScale.headline, weight: .bold))
            .foregroundStyle(Color.textPrimary)

          let tagLayout = isCompact
            ? AnyLayout(WrappingFlowLayout(spacing: Spacing.xs))
            : AnyLayout(HStackLayout(spacing: Spacing.sm))

          tagLayout {
            capsuleTag(mission.trackerKind.capitalized, icon: "link")
            capsuleTag(mission.resolvedProvider.displayName, icon: mission.resolvedProvider.icon)
            if mission.providerStrategy != "single", mission.secondaryProvider != nil {
              capsuleTag(
                mission.providerStrategy.replacingOccurrences(of: "_", with: " ").capitalized,
                icon: "arrow.triangle.branch"
              )
            }
            statusCapsule(mission)
          }
        }

        Spacer()
      }
    }
  }

  // MARK: - Actions

  #if os(macOS)
    private func missionActions(_ mission: MissionSummary) -> some View {
      Menu {
        missionActionMenuContent
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.textTertiary)
          .frame(width: 28, height: 28)
          .background(
            Color.backgroundTertiary.opacity(0.6),
            in: RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
          )
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .alert("Delete Mission?", isPresented: $viewModel.showDeleteConfirmation) {
        Button("Delete", role: .destructive) {
          Task {
            if await viewModel.deleteMission() {
              router.selectDashboardTab(.missions)
            }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Are you sure you want to delete this mission? This cannot be undone.")
      }
    }
  #else
    private func iOSActionsMenu(_ mission: MissionSummary) -> some View {
      Menu {
        missionActionMenuContent
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .alert("Delete Mission?", isPresented: $viewModel.showDeleteConfirmation) {
        Button("Delete", role: .destructive) {
          Task {
            if await viewModel.deleteMission() {
              router.selectDashboardTab(.missions)
            }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Are you sure you want to delete this mission? This cannot be undone.")
      }
    }
  #endif

  @ViewBuilder
  private var missionActionMenuContent: some View {
    Button {
      viewModel.showWorktreeCleanup = true
      Task { await viewModel.loadMissionWorktrees() }
    } label: {
      Label("Clean Up Worktrees", systemImage: "arrow.3.trianglepath")
    }

    Divider()

    Button(role: .destructive) {
      viewModel.showDeleteConfirmation = true
    } label: {
      Label("Delete Mission", systemImage: "trash")
    }
  }

  // MARK: - Helpers

  private func statusCapsule(_ mission: MissionSummary) -> some View {
    let icon = if !mission.enabled {
      "circle"
    } else if mission.paused {
      "pause.circle.fill"
    } else {
      switch mission.orchestratorStatus {
        case "no_api_key": "key"
        case "config_error": "exclamationmark.triangle.fill"
        case "polling": "antenna.radiowaves.left.and.right"
        default: "circle"
      }
    }

    return capsuleStatus(mission.statusLabel, icon: icon, color: mission.statusColor)
  }

  private func capsuleTag(_ text: String, icon: String) -> some View {
    Label(text, systemImage: icon)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(Color.backgroundTertiary, in: Capsule())
  }

  private func capsuleStatus(_ text: String, icon: String, color: Color) -> some View {
    Label(text, systemImage: icon)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(color.opacity(OpacityTier.light), in: Capsule())
  }

}

// MARK: - Tab Enum

enum MissionTab: String, CaseIterable {
  case overview
  case settings
  case issues

  var title: String {
    switch self {
      case .overview: "Overview"
      case .settings: "Settings"
      case .issues: "Issues"
    }
  }

  var icon: String {
    switch self {
      case .overview: "gauge.with.dots.needle.33percent"
      case .settings: "gearshape"
      case .issues: "list.bullet"
    }
  }
}
