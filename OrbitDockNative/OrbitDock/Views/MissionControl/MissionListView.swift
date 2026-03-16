import SwiftUI

struct MissionListView: View {
  @State private var missions: [MissionSummary] = []
  @State private var isLoading = true
  @State private var error: String?
  @State private var selectedMissionId: String?
  @State private var showNewMission = false

  let http: ServerHTTPClient

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
    .sheet(item: selectedMissionBinding) { mission in
      MissionDetailView(missionId: mission.id, http: http)
    }
    .sheet(isPresented: $showNewMission) {
      NewMissionSheet(http: http) { newMission in
        missions.insert(newMission, at: 0)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: Spacing.lg) {
      ContentUnavailableView(
        "No Missions",
        systemImage: "antenna.radiowaves.left.and.right",
        description: Text("Enable Mission Control for a repository with WORKFLOW.md")
      )

      Button {
        showNewMission = true
      } label: {
        Label("New Mission", systemImage: "plus")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.white)
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.md_)
          .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(Color.accent)
          )
      }
      .buttonStyle(.plain)
    }
  }

  private var missionsList: some View {
    ScrollView {
      VStack(spacing: Spacing.sm) {
        HStack {
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
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                  .fill(Color.accent.opacity(OpacityTier.light))
              )
          }
          .buttonStyle(.plain)
        }

        ForEach(missions) { mission in
          Button {
            selectedMissionId = mission.id
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

  private var selectedMissionBinding: Binding<MissionSummary?> {
    Binding(
      get: {
        guard let id = selectedMissionId else { return nil }
        return missions.first { $0.id == id }
      },
      set: { newValue in
        selectedMissionId = newValue?.id
      }
    )
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

private struct MissionRowView: View {
  let mission: MissionSummary
  let http: ServerHTTPClient
  let onRefresh: () async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack {
        Text(repoName)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        Spacer()

        missionActions

        if mission.paused {
          statusCapsule("Paused", icon: "pause.circle.fill", color: Color.textTertiary)
        } else if mission.enabled {
          statusCapsule("Active", icon: "circle.fill", color: Color.feedbackPositive)
        } else {
          statusCapsule("Disabled", icon: "circle", color: Color.textTertiary)
        }
      }

      HStack(spacing: Spacing.md) {
        metricLabel("\(mission.activeCount)", icon: "play.circle", color: .blue)
        metricLabel("\(mission.queuedCount)", icon: "clock", color: .orange)
        metricLabel("\(mission.completedCount)", icon: "checkmark.circle", color: .green)
        if mission.failedCount > 0 {
          metricLabel("\(mission.failedCount)", icon: "xmark.circle", color: .red)
        }
      }
      .font(.system(size: TypeScale.caption, weight: .medium))

      if let parseError = mission.parseError {
        Text(parseError)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.statusError)
          .lineLimit(2)
      }
    }
    .padding(Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
        )
    )
  }

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
        Task { await deleteMission() }
      } label: {
        Label("Delete", systemImage: "trash")
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 24, height: 24)
        .background(Color.backgroundTertiary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.sm_, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
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

  private func statusCapsule(_ label: String, icon: String, color: Color) -> some View {
    Label(label, systemImage: icon)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(color.opacity(OpacityTier.light), in: Capsule())
  }

  private func metricLabel(_ value: String, icon: String, color: Color) -> some View {
    Label(value, systemImage: icon)
      .foregroundStyle(color)
  }

  private var repoName: String {
    mission.repoRoot
      .split(separator: "/")
      .last
      .map(String.init) ?? mission.repoRoot
  }
}

private struct UpdateMissionBody: Encodable {
  let enabled: Bool?
  let paused: Bool?
}

private struct GenericOkResponse: Decodable {
  let ok: Bool?
}
