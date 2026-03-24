import SwiftUI

struct MissionListView: View {
  @State private var viewModel = MissionListViewModel()

  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

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
      await viewModel.fetchAllMissions()
    }
    .onChange(of: viewModel.aggregatedMissionsSnapshot) { _, _ in
      viewModel.applyMissionListSnapshotIfNeeded()
    }
    .sheet(isPresented: $viewModel.showNewMission) {
      NewMissionSheet { newMission, endpointId in
        let agg = AggregatedMissionSummary(
          mission: newMission,
          endpointId: endpointId,
          endpointName: runtimeRegistry.runtimesByEndpointId[endpointId]?.endpoint.name
        )
        viewModel.missions.insert(agg, at: 0)
        router.navigateToMission(missionId: newMission.id, endpointId: endpointId)
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
      VStack(alignment: .leading, spacing: Spacing.lg) {
        MissionOverviewHeader(
          missions: viewModel.missions,
          onNewMission: { viewModel.showNewMission = true }
        )

        ForEach(viewModel.missions) { agg in
          let missionsClient = runtimeRegistry.runtimesByEndpointId[agg.endpointId]?.clients.missions

          Button {
            router.navigateToMission(missionId: agg.mission.id, endpointId: agg.endpointId)
          } label: {
            MissionRowView(
              mission: agg.mission,
              endpointName: runtimeRegistry.hasMultipleEndpoints ? agg.endpointName : nil,
              missionsClient: missionsClient,
              onRefresh: { await viewModel.fetchAllMissions() },
              onApplyList: { response in
                // Update just this endpoint's missions in the list
                let endpointId = agg.endpointId
                let endpointName = agg.endpointName
                let updated = response.missions.map { mission in
                  AggregatedMissionSummary(mission: mission, endpointId: endpointId, endpointName: endpointName)
                }
                withAnimation(Motion.standard) {
                  viewModel.missions.removeAll { $0.endpointId == endpointId }
                  viewModel.missions.append(contentsOf: updated)
                  viewModel.missions.sort { lhs, rhs in
                    let lhsActive = lhs.mission.enabled && !lhs.mission.paused
                    let rhsActive = rhs.mission.enabled && !rhs.mission.paused
                    if lhsActive != rhsActive { return lhsActive }
                    return lhs.mission.name.localizedCaseInsensitiveCompare(rhs.mission.name) == .orderedAscending
                  }
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

private struct MissionOverviewHeader: View {
  let missions: [AggregatedMissionSummary]
  let onNewMission: () -> Void

  private var activeCount: Int {
    missions.filter { $0.mission.enabled && !$0.mission.paused }.count
  }

  private var pausedCount: Int {
    missions.filter(\.mission.paused).count
  }

  private var repoCount: Int {
    Set(missions.map(\.mission.repoRoot)).count
  }

  private var activeIssues: Int {
    missions.reduce(0) { $0 + Int($1.mission.activeCount) }
  }

  private var queuedIssues: Int {
    missions.reduce(0) { $0 + Int($1.mission.queuedCount) }
  }

  private var completedIssues: Int {
    missions.reduce(0) { $0 + Int($1.mission.completedCount) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      HStack(alignment: .top, spacing: Spacing.lg) {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text("AUTONOMOUS ORCHESTRATION")
            .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)

          HStack(spacing: Spacing.sm) {
            Text("Mission Control")
              .font(.system(size: TypeScale.headline, weight: .bold, design: .rounded))
              .foregroundStyle(Color.textPrimary)

            Text("\(missions.count)")
              .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xxs)
              .background(Color.backgroundTertiary, in: Capsule())
          }

          Text("A cleaner flight deck for every repository mission, with status that stays stable as live updates stream in.")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560, alignment: .leading)
        }

        Spacer(minLength: Spacing.md)

        Button(action: onNewMission) {
          Label("New Mission", systemImage: "plus")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.accent)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Color.accent.opacity(OpacityTier.light))
            )
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Color.accent.opacity(OpacityTier.medium), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
      }

      metricsGrid
    }
    .padding(Spacing.lg)
    .background(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
    .shadow(color: Color.accent.opacity(0.05), radius: 18, y: 6)
  }

  @ViewBuilder
  private var metricsGrid: some View {
    ViewThatFits(in: .horizontal) {
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.md, alignment: .top), count: 4),
        alignment: .leading,
        spacing: Spacing.md
      ) {
        metricCards
      }

      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.md, alignment: .top), count: 2),
        alignment: .leading,
        spacing: Spacing.md
      ) {
        metricCards
      }

      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: Spacing.md, alignment: .top)],
        alignment: .leading,
        spacing: Spacing.md
      ) {
        metricCards
      }
    }
  }

  private var metricCards: some View {
    Group {
      MissionOverviewMetric(title: "Active Missions", value: "\(activeCount)", detail: "\(repoCount) repos", tint: .feedbackPositive)
      MissionOverviewMetric(title: "Paused", value: "\(pausedCount)", detail: "Hold + resume", tint: .feedbackCaution)
      MissionOverviewMetric(title: "Issues In Flight", value: "\(activeIssues)", detail: "\(queuedIssues) queued", tint: .accent)
      MissionOverviewMetric(title: "Completed", value: "\(completedIssues)", detail: "Across all missions", tint: .textTertiary)
    }
  }
}

private struct MissionOverviewMetric: View {
  let title: String
  let value: String
  let detail: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      Text(title.uppercased())
        .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)

      Text(value)
        .font(.system(size: TypeScale.headline, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Text(detail)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.lg_)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundCode)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(0.7), lineWidth: 1)
    )
    .overlay(alignment: .topLeading) {
      Capsule()
        .fill(tint.opacity(OpacityTier.vivid))
        .frame(width: 18, height: 3)
        .padding(.leading, Spacing.md)
        .padding(.top, Spacing.sm)
    }
    .shadow(color: tint.opacity(0.08), radius: 12, y: 4)
  }
}

// MARK: - Mission Row

private struct MissionRowView: View {
  let mission: MissionSummary
  let endpointName: String?
  let missionsClient: MissionsClient?
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

  private var statusGlowColor: Color {
    if mission.paused { return .feedbackCaution }
    if mission.enabled { return .accent }
    return .clear
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .top, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(mission.repoName)
              .font(.system(size: TypeScale.large, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.textPrimary)

            if mission.repoName.localizedCaseInsensitiveCompare(mission.name) != .orderedSame {
              Text(mission.name)
                .font(.system(size: TypeScale.caption, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
            }
          }

          Text(mission.repoRoot)
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: Spacing.md)

        HStack(spacing: Spacing.sm) {
          statusBadge
          MissionSignalPill(label: mission.flightStatus, icon: "antenna.radiowaves.left.and.right", tint: mission.flightStatusColor)
          missionActions
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Spacing.lg) {
          missionDetailsColumn

          Rectangle()
            .fill(Color.surfaceBorder.opacity(0.8))
            .frame(width: 1)
            .padding(.vertical, Spacing.xs)

          missionSummaryPanel
        }

        VStack(alignment: .leading, spacing: Spacing.md) {
          missionDetailsColumn
          missionSummaryPanel
        }
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.lg_)
    .background(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(isHovering ? Color.surfaceHover : Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(isHovering ? 1 : 0.45), lineWidth: 1)
    )
    .shadow(color: statusGlowColor.opacity(isHovering ? 0.12 : 0.05), radius: 18, y: 6)
    .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
    .onHover { hovering in
      withAnimation(Motion.hover) { isHovering = hovering }
    }
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  private var missionDetailsColumn: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm_) {
        if let endpointName {
          MissionMetaChip(label: endpointName, icon: "server.rack", tint: .textTertiary, fill: Color.backgroundTertiary)
        }
        MissionMetaChip(
          label: mission.resolvedProvider.displayName,
          icon: mission.resolvedProvider.icon,
          tint: mission.resolvedProvider.accentColor,
          fill: mission.resolvedProvider.accentColor.opacity(OpacityTier.subtle)
        )
        MissionMetaChip(label: mission.trackerKind.capitalized, icon: "link", tint: .textTertiary, fill: Color.backgroundTertiary)
        if totalIssues > 0 {
          MissionMetaChip(
            label: "\(totalIssues) tracked",
            icon: "number",
            tint: .textSecondary,
            fill: Color.backgroundTertiary
          )
        }
      }

      statusContent
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var missionSummaryPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: "waveform.path.ecg")
          .font(.system(size: IconScale.xs, weight: .semibold))
          .foregroundStyle(mission.flightStatusColor)

        Text("Mission Pulse")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }

      if hasAnyIssues {
        HStack(spacing: Spacing.sm) {
          MissionSummaryMetric(value: mission.activeCount, label: "Active", tint: .statusWorking)
          MissionSummaryMetric(value: mission.queuedCount, label: "Queued", tint: .feedbackCaution)
          MissionSummaryMetric(value: mission.completedCount, label: "Done", tint: .feedbackPositive)

          if mission.failedCount > 0 {
            MissionSummaryMetric(value: mission.failedCount, label: "Failed", tint: .feedbackNegative)
          }
        }
      } else {
        HStack(spacing: Spacing.sm_) {
          Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)

          Text(mission.flightStatus)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(statusColor)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundCode)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(0.6), lineWidth: 1)
    )
  }

  @ViewBuilder
  private var statusContent: some View {
    if needsSetup {
      MissionBanner(
        icon: "bolt.horizontal.circle",
        text: "Needs mission file setup",
        tint: .accent
      )
    } else if let parseError = mission.parseError {
      MissionBanner(
        icon: "exclamationmark.triangle",
        text: parseError,
        tint: .feedbackNegative
      )
    } else if hasAnyIssues {
      MissionBanner(
        icon: "checklist",
        text: totalIssues == 1 ? "1 tracked issue moving through this mission" : "\(totalIssues) tracked issues moving through this mission",
        tint: .textTertiary
      )
    } else if mission.orchestratorStatus == "no_api_key" {
      MissionBanner(
        icon: "exclamationmark.triangle",
        text: "API key needed",
        tint: .feedbackCaution
      )
    } else {
      MissionBanner(
        icon: "antenna.radiowaves.left.and.right",
        text: "Polling for issues",
        tint: .textQuaternary
      )
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
      .shadow(color: color.opacity(0.14), radius: 10, y: 2)
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
        .frame(width: 26, height: 26)
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
    guard let missionsClient else { return }
    do {
      _ = try await missionsClient.updateMission(mission.id, enabled: enabled, paused: paused)
      await onRefresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func deleteMission() async {
    guard let missionsClient else { return }
    do {
      let response = try await missionsClient.deleteMission(mission.id)
      onApplyList(response)
    } catch {
      actionError = error.localizedDescription
    }
  }
}

private struct MissionMetaChip: View {
  let label: String
  let icon: String
  let tint: Color
  let fill: Color

  var body: some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: icon)
        .font(.system(size: IconScale.xs, weight: .semibold))
      Text(label)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.xxs)
    .background(fill, in: Capsule())
  }
}

private struct MissionSignalPill: View {
  let label: String
  let icon: String
  let tint: Color

  var body: some View {
    Label(label, systemImage: icon)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(tint.opacity(OpacityTier.light), in: Capsule())
      .overlay(
        Capsule()
          .stroke(tint.opacity(OpacityTier.medium), lineWidth: 1)
      )
      .shadow(color: tint.opacity(0.10), radius: 10, y: 2)
  }
}

private struct MissionBanner: View {
  let icon: String
  let text: String
  let tint: Color

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: icon)
        .font(.system(size: IconScale.sm, weight: .medium))
        .foregroundStyle(tint)

      Text(text)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(tint)
        .lineLimit(1)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundCode)
    )
  }
}

private struct MissionSummaryMetric: View {
  let value: UInt32
  let label: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text("\(value)")
        .font(.system(size: TypeScale.large, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.textPrimary)

      HStack(spacing: Spacing.xxs) {
        Circle()
          .fill(tint)
          .frame(width: 5, height: 5)

        Text(label)
          .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
