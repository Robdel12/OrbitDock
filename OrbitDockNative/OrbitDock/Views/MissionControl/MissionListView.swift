import SwiftUI

struct MissionListView: View {
  @State private var viewModel = MissionListViewModel()

  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let missionsClient: MissionsClient

  var body: some View {
    Group {
      if viewModel.isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = viewModel.error {
        ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
      } else if viewModel.missions.isEmpty {
        emptyState
      } else {
        missionsList
      }
    }
    .task {
      viewModel.bind(runtimeRegistry: runtimeRegistry)
      await viewModel.fetchMissions(using: missionsClient)
    }
    .onChange(of: viewModel.missionListSnapshot) { _, _ in
      viewModel.applyMissionListSnapshotIfNeeded()
    }
    .sheet(isPresented: $viewModel.showNewMission) {
      NewMissionSheet(missionsClient: missionsClient) { newMission in
        viewModel.missions.insert(newMission, at: 0)
        router.navigateToMission(missionId: newMission.id, endpointId: viewModel.endpointId)
      }
    }
    .alert(
      "Error",
      isPresented: Binding(get: { viewModel.actionError != nil }, set: { if !$0 { viewModel.actionError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(viewModel.actionError ?? "")
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: Spacing.xl) {
      Spacer()

      VStack(spacing: Spacing.lg) {
        MissionEmptyState(
          icon: "antenna.radiowaves.left.and.right",
          title: "Mission Control",
          subtitle: "Autonomous issue-driven agent orchestration.\nPoint a mission at a repository and let agents work through your backlog.",
          iconColor: .accent
        )

        Button {
          viewModel.showNewMission = true
        } label: {
          Label("New Mission", systemImage: "plus")
        }
        .buttonStyle(CosmicButtonStyle(color: .accent, size: .large))
      }
      .frame(maxWidth: 320)

      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Mission List

  private var missionsList: some View {
    ScrollView {
      VStack(spacing: Spacing.md) {
        // Header bar
        HStack {
          Text("Missions")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Text("\(viewModel.missions.count)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)

          Spacer()

          Button {
            viewModel.showNewMission = true
          } label: {
            Label("New Mission", systemImage: "plus")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.accent)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm_)
              .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  .fill(Color.accent.opacity(OpacityTier.light))
              )
          }
          .buttonStyle(.plain)
        }

        ForEach(viewModel.missions) { mission in
          Button {
            router.navigateToMission(missionId: mission.id, endpointId: viewModel.endpointId)
          } label: {
            MissionRowView(
              mission: mission,
              missionsClient: missionsClient,
              onRefresh: { await viewModel.fetchMissions(using: missionsClient) },
              onApplyList: { response in
                withAnimation(Motion.standard) {
                  viewModel.missions = response.missions
                }
              }
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(Spacing.section)
    }
  }

}

// MARK: - Mission Row

private struct MissionRowView: View {
  let mission: MissionSummary
  let missionsClient: MissionsClient
  let onRefresh: () async -> Void
  let onApplyList: (MissionsListResponse) -> Void

  @State private var isHovering = false
  @State private var showDeleteConfirmation = false
  @State private var actionError: String?

  private var statusColor: Color {
    if mission.paused { return Color.feedbackCaution }
    if mission.enabled { return Color.feedbackPositive }
    return Color.textQuaternary
  }

  private var needsSetup: Bool {
    mission.parseError?.contains("not found") == true
  }

  private var hasAnyIssues: Bool {
    mission.activeCount + mission.queuedCount + mission.completedCount + mission.failedCount > 0
  }

  private var totalIssues: UInt32 {
    mission.activeCount + mission.queuedCount + mission.completedCount + mission.failedCount
  }

  var body: some View {
    HStack(spacing: 0) {
      // Left status edge
      RoundedRectangle(cornerRadius: 1.5)
        .fill(statusColor)
        .frame(width: EdgeBar.width)
        .padding(.vertical, Spacing.sm)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Top row: name + badges + actions
        HStack(alignment: .center) {
          Text(mission.name)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          // Provider tag
          HStack(spacing: Spacing.gap) {
            Image(systemName: mission.resolvedProvider.icon)
              .font(.system(size: IconScale.xs, weight: .semibold))
            Text(mission.resolvedProvider.displayName)
              .font(.system(size: TypeScale.mini, weight: .semibold))
          }
          .foregroundStyle(mission.resolvedProvider.accentColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(mission.resolvedProvider.accentColor.opacity(OpacityTier.subtle), in: Capsule())

          // Tracker tag
          HStack(spacing: Spacing.gap) {
            Image(systemName: "link")
              .font(.system(size: IconScale.xs, weight: .semibold))
            Text(mission.trackerKind.capitalized)
              .font(.system(size: TypeScale.mini, weight: .semibold))
          }
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(Color.backgroundTertiary, in: Capsule())

          Spacer()

          missionActions

          statusBadge
        }

        // Repo path
        Text(mission.repoRoot)
          .font(.system(size: TypeScale.micro, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .fixedSize(horizontal: false, vertical: true)

        // Bottom row: contextual status
        if needsSetup {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "bolt.horizontal.circle")
              .font(.system(size: IconScale.sm, weight: .medium))
              .foregroundStyle(Color.accent)
            Text("Needs mission file setup")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.accent)

            Image(systemName: "chevron.right")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(Color.accent.opacity(OpacityTier.strong))
          }
        } else if let parseError = mission.parseError {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: IconScale.sm))
              .foregroundStyle(Color.feedbackNegative)
            Text(parseError)
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.feedbackNegative)
              .lineLimit(1)
          }
        } else if hasAnyIssues {
          // Has real data — show stats
          HStack(spacing: Spacing.lg_) {
            MissionStatChip(count: mission.activeCount, label: "Active", color: Color.statusWorking)
            MissionStatChip(count: mission.queuedCount, label: "Queued", color: Color.feedbackCaution)
            MissionStatChip(count: mission.completedCount, label: "Done", color: Color.feedbackPositive)

            if mission.failedCount > 0 {
              MissionStatChip(count: mission.failedCount, label: "Failed", color: Color.feedbackNegative)
            }
          }
        } else if mission.orchestratorStatus == "no_api_key" {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: IconScale.sm))
              .foregroundStyle(Color.feedbackCaution)
            Text("API key needed")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.feedbackCaution)
          }
        } else {
          // Zero issues — show polling status
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "antenna.radiowaves.left.and.right")
              .font(.system(size: IconScale.sm))
              .foregroundStyle(Color.textQuaternary)
            Text("Polling for issues")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textQuaternary)
          }
        }
      }
      .padding(.leading, Spacing.md)
      .padding(.trailing, Spacing.lg_)
      .padding(.vertical, Spacing.md)
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(isHovering ? Color.surfaceHover : Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.surfaceBorder, lineWidth: isHovering ? 1 : 0)
    )
    .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
    .onHover { hovering in
      withAnimation(Motion.hover) { isHovering = hovering }
    }
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  // MARK: - Status Badge

  private var statusBadge: some View {
    Group {
      if mission.paused {
        capsuleBadge("Paused", icon: "pause.circle.fill", color: Color.feedbackCaution)
      } else if mission.enabled {
        capsuleBadge("Active", icon: "circle.fill", color: Color.feedbackPositive)
      } else {
        capsuleBadge("Disabled", icon: "circle", color: Color.textQuaternary)
      }
    }
  }

  private func capsuleBadge(_ label: String, icon: String, color: Color) -> some View {
    Label(label, systemImage: icon)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(color.opacity(OpacityTier.light), in: Capsule())
  }

  // MARK: - Stat Pills

  // MARK: - Actions Menu

  private var missionActions: some View {
    Menu {
      if mission.paused {
        Button {
          Task { await updateMission(paused: false) }
        } label: {
          Label("Resume", systemImage: "play.fill")
        }
      } else {
        Button {
          Task { await updateMission(paused: true) }
        } label: {
          Label("Pause", systemImage: "pause.fill")
        }
      }

      Divider()

      if mission.enabled {
        Button {
          Task { await updateMission(enabled: false) }
        } label: {
          Label("Disable", systemImage: "stop.circle")
        }
      } else {
        Button {
          Task { await updateMission(enabled: true) }
        } label: {
          Label("Enable", systemImage: "play.circle")
        }
      }

      Divider()

      Button(role: .destructive) {
        showDeleteConfirmation = true
      } label: {
        Label("Delete", systemImage: "trash")
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 24, height: 24)
        .background(
          Color.backgroundTertiary.opacity(0.6),
          in: RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous)
        )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .alert("Delete Mission?", isPresented: $showDeleteConfirmation) {
      Button("Delete", role: .destructive) {
        Task { await deleteMission() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Are you sure you want to delete \"\(mission.name)\"? This cannot be undone.")
    }
  }

  // MARK: - Helpers

  private func updateMission(enabled: Bool? = nil, paused: Bool? = nil) async {
    do {
      _ = try await missionsClient.updateMission(mission.id, enabled: enabled, paused: paused)
      await onRefresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func deleteMission() async {
    do {
      let response = try await missionsClient.deleteMission(mission.id)
      onApplyList(response)
    } catch {
      actionError = error.localizedDescription
    }
  }
}
