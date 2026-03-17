import SwiftUI

struct MissionShowView: View {
  let missionId: String
  let endpointId: UUID

  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  @State private var summary: MissionSummary?
  @State private var issues: [MissionIssueItem] = []
  @State private var settings: MissionSettings?
  @State private var missionFileExists = true
  @State private var missionFilePath: String?
  @State private var workflowMigrationAvailable = false
  @State private var isLoading = true
  @State private var error: String?
  @State private var selectedTab: MissionTab = .overview
  @State private var showDeleteConfirmation = false
  @State private var actionError: String?

  private var isCompact: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private var runtime: ServerRuntime? {
    runtimeRegistry.runtimesByEndpointId[endpointId] ?? runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime
  }

  private var http: ServerHTTPClient? {
    runtime?.clients.http
  }

  private var sessionStore: SessionStore? {
    runtime?.sessionStore
  }

  var body: some View {
    VStack(spacing: 0) {
      navigationBar
      Divider().foregroundStyle(Color.surfaceBorder)

      Group {
        if isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
          ContentUnavailableView(
            "Failed to Load Mission",
            systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
        } else if let summary {
          missionContent(summary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.backgroundPrimary)
    .task {
      await fetchDetail()
    }
    .onChange(of: sessionStore?.missionDeltaRevision) { _, _ in
      guard let store = sessionStore,
            store.missionDeltaMissionId == missionId,
            let deltaSummary = store.missionDeltaSummary
      else { return }
      summary = deltaSummary
      issues = store.missionDeltaIssues
    }
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  // MARK: - Navigation Bar

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

      if let summary {
        missionActions(summary)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .background(Color.backgroundSecondary)
  }

  // MARK: - Content

  private func missionContent(_ mission: MissionSummary) -> some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xl) {
          missionHeader(mission)
          tabBar

          switch selectedTab {
            case .overview:
              MissionOverviewTab(
                mission: mission,
                settings: settings,
                issues: issues,
                missionId: missionId,
                missionFileExists: missionFileExists,
                workflowMigrationAvailable: workflowMigrationAvailable,
                http: http,
                isCompact: isCompact,
                endpointId: endpointId,
                sessionStore: sessionStore,
                onRefresh: { await fetchDetail() },
                onApplyDetail: { applyDetail($0) },
                onSelectTab: { tab in
                  withAnimation(Motion.standard) { selectedTab = tab }
                },
                onUpdateMission: { enabled, paused in
                  await updateMission(enabled: enabled, paused: paused)
                },
                onNavigateToSession: { sessionId in
                  let ref = SessionRef(endpointId: endpointId, sessionId: sessionId)
                  router.selectSession(ref, source: .external)
                }
              )
            case .settings:
              MissionSettingsTab(
                settings: settings,
                repoRoot: mission.repoRoot,
                missionId: missionId,
                http: http,
                isCompact: isCompact,
                onUpdated: { await fetchDetail() }
              )
            case .issues:
              MissionIssuesTab(
                issues: issues,
                missionId: missionId,
                endpointId: endpointId,
                http: http
              )
          }
        }
        .padding(Spacing.section)
      }
    }
  }

  // MARK: - Tab Bar

  private var tabBar: some View {
    HStack(spacing: Spacing.sm) {
      ForEach(MissionTab.allCases, id: \.self) { tab in
        Button {
          withAnimation(Motion.standard) {
            selectedTab = tab
          }
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: tab.icon)
              .font(.system(size: IconScale.sm, weight: .semibold))
            Text(tab.title)
              .font(.system(size: TypeScale.meta, weight: .semibold))
            if tab == .issues, !issues.isEmpty {
              Text("\(issues.count)")
                .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
                .foregroundStyle(selectedTab == tab ? Color.accent : Color.textQuaternary)
            }
          }
          .foregroundStyle(selectedTab == tab ? Color.accent : Color.textSecondary)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
          .background(
            Capsule(style: .continuous)
              .fill(selectedTab == tab ? Color.surfaceSelected : Color.backgroundTertiary.opacity(0.8))
          )
          .overlay(
            Capsule(style: .continuous)
              .strokeBorder(selectedTab == tab ? Color.surfaceBorder : .clear, lineWidth: 1)
          )
        }
        .buttonStyle(.plain)
      }

      Spacer()
    }
  }

  // MARK: - Header

  private func missionHeader(_ mission: MissionSummary) -> some View {
    HStack(alignment: .center, spacing: Spacing.md) {
      ZStack {
        Circle()
          .fill(mission.statusColor.opacity(OpacityTier.light))
          .frame(width: 32, height: 32)

        Circle()
          .fill(mission.statusColor)
          .frame(width: 8, height: 8)
      }

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

  // MARK: - Actions

  private func missionActions(_ mission: MissionSummary) -> some View {
    Menu {
      Button(role: .destructive) {
        showDeleteConfirmation = true
      } label: {
        Label("Delete Mission", systemImage: "trash")
      }
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
    .alert("Delete Mission?", isPresented: $showDeleteConfirmation) {
      Button("Delete", role: .destructive) {
        Task { await deleteMission() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Are you sure you want to delete this mission? This cannot be undone.")
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

  // MARK: - Networking

  private func applyDetail(_ response: MissionDetailResponse) {
    summary = response.summary
    issues = response.issues
    settings = response.settings
    missionFileExists = response.missionFileExists
    missionFilePath = response.missionFilePath
    workflowMigrationAvailable = response.workflowMigrationAvailable
    error = nil
  }

  private func fetchDetail() async {
    guard let http else {
      error = "No server connection"
      isLoading = false
      return
    }

    let isInitialLoad = summary == nil
    if isInitialLoad { isLoading = true }
    do {
      let response: MissionDetailResponse = try await http.get("/api/missions/\(missionId)")
      applyDetail(response)
    } catch {
      self.error = error.localizedDescription
    }
    if isInitialLoad { isLoading = false }
  }

  private func updateMission(enabled: Bool? = nil, paused: Bool? = nil) async {
    guard let http else { return }
    let body = MissionUpdateBody(name: nil, enabled: enabled, paused: paused)
    do {
      let response: MissionDetailResponse = try await http.request(
        path: "/api/missions/\(missionId)",
        method: "PUT",
        body: body
      )
      applyDetail(response)
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func deleteMission() async {
    guard let http else { return }
    do {
      let _: MissionOkResponse = try await http.request(
        path: "/api/missions/\(missionId)",
        method: "DELETE"
      )
      router.selectDashboardTab(.missions)
    } catch {
      actionError = error.localizedDescription
    }
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
