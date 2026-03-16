import SwiftUI

struct MissionListView: View {
  @State private var missions: [MissionSummary] = []
  @State private var isLoading = true
  @State private var error: String?
  @State private var showNewMission = false

  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let http: ServerHTTPClient

  private var sessionStore: SessionStore? {
    (runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime)?.sessionStore
  }

  private var endpointId: UUID {
    runtimeRegistry.primaryEndpointId
      ?? runtimeRegistry.activeEndpointId
      ?? UUID()
  }

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error {
        ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
      } else if missions.isEmpty {
        emptyState
      } else {
        missionsList
      }
    }
    .task {
      await fetchMissions()
    }
    .onChange(of: sessionStore?.missionListSnapshot) { _, newSnapshot in
      guard let newSnapshot, !newSnapshot.isEmpty else { return }
      missions = newSnapshot
    }
    .sheet(isPresented: $showNewMission) {
      NewMissionSheet(http: http) { newMission in
        missions.insert(newMission, at: 0)
        router.navigateToMission(missionId: newMission.id, endpointId: endpointId)
      }
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: Spacing.xl) {
      Spacer()

      VStack(spacing: Spacing.lg) {
        ZStack {
          Circle()
            .fill(Color.accent.opacity(OpacityTier.subtle))
            .frame(width: 64, height: 64)

          Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(Color.accent)
        }

        VStack(spacing: Spacing.sm_) {
          Text("Mission Control")
            .font(.system(size: TypeScale.large, weight: .bold))
            .foregroundStyle(Color.textPrimary)

          Text(
            "Autonomous issue-driven agent orchestration.\nPoint a mission at a repository and let agents work through your backlog."
          )
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }

        Button {
          showNewMission = true
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

          Text("\(missions.count)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)

          Spacer()

          Button {
            showNewMission = true
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

        ForEach(missions) { mission in
          Button {
            router.navigateToMission(missionId: mission.id, endpointId: endpointId)
          } label: {
            MissionRowView(mission: mission, http: http) {
              await fetchMissions()
            }
          }
          .buttonStyle(.plain)
        }
      }
      .padding(Spacing.section)
    }
  }

  private func fetchMissions() async {
    isLoading = true
    do {
      let response: MissionsListResponse = try await http.get("/api/missions")
      missions = response.missions
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
    isLoading = false
  }
}

private struct MissionsListResponse: Codable {
  let missions: [MissionSummary]
}

// MARK: - Mission Row

private struct MissionRowView: View {
  let mission: MissionSummary
  let http: ServerHTTPClient
  let onRefresh: () async -> Void

  @State private var isHovering = false
  @State private var showDeleteConfirmation = false

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
          Text(repoName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          // Provider tag
          HStack(spacing: Spacing.gap) {
            Image(systemName: providerIcon)
              .font(.system(size: IconScale.xs, weight: .semibold))
            Text(mission.provider.capitalized)
              .font(.system(size: TypeScale.mini, weight: .semibold))
          }
          .foregroundStyle(providerColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, Spacing.xxs)
          .background(providerColor.opacity(OpacityTier.subtle), in: Capsule())

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
            Text("Needs WORKFLOW.md setup")
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
            statPill(count: mission.activeCount, label: "Active", color: Color.statusWorking)
            statPill(count: mission.queuedCount, label: "Queued", color: Color.feedbackCaution)
            statPill(count: mission.completedCount, label: "Done", color: Color.feedbackPositive)

            if mission.failedCount > 0 {
              statPill(count: mission.failedCount, label: "Failed", color: Color.feedbackNegative)
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

  private func statPill(count: UInt32, label: String, color: Color) -> some View {
    HStack(spacing: Spacing.xs) {
      Text("\(count)")
        .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
        .foregroundStyle(count > 0 ? color : Color.textQuaternary)

      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }

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
      Text("Are you sure you want to delete the mission for \(repoName)? This cannot be undone.")
    }
  }

  // MARK: - Helpers

  private var providerIcon: String {
    switch mission.provider.lowercased() {
      case "codex": "terminal"
      default: "cpu"
    }
  }

  private var providerColor: Color {
    switch mission.provider.lowercased() {
      case "codex": Color.providerCodex
      default: Color.providerClaude
    }
  }

  private var repoName: String {
    mission.repoRoot
      .split(separator: "/")
      .last
      .map(String.init) ?? mission.repoRoot
  }

  private func updateMission(enabled: Bool? = nil, paused: Bool? = nil) async {
    let body = UpdateMissionBody(enabled: enabled, paused: paused)
    do {
      let _: GenericOkResponse = try await http.request(
        path: "/api/missions/\(mission.id)",
        method: "PUT",
        body: body
      )
      await onRefresh()
    } catch {
      print("[OrbitDock] Failed to update mission: \(error)")
    }
  }

  private func deleteMission() async {
    do {
      let _: GenericOkResponse = try await http.request(
        path: "/api/missions/\(mission.id)",
        method: "DELETE"
      )
      await onRefresh()
    } catch {
      print("[OrbitDock] Failed to delete mission: \(error)")
    }
  }
}

private struct UpdateMissionBody: Encodable {
  let enabled: Bool?
  let paused: Bool?
}

private struct GenericOkResponse: Decodable {
  let ok: Bool?
}
