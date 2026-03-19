import SwiftUI

struct MissionOverviewTab: View {
  let mission: MissionSummary
  let settings: MissionSettings?
  let issues: [MissionIssueItem]
  let missionId: String
  let missionFileExists: Bool
  let workflowMigrationAvailable: Bool
  let http: ServerHTTPClient?
  let isCompact: Bool
  let endpointId: UUID
  let sessionStore: SessionStore?
  let nextTickAt: Date?
  let lastTickAt: Date?
  let onRefresh: () async -> Void
  let onApplyDetail: (MissionDetailResponse) -> Void
  let onSelectTab: (MissionTab) -> Void
  let onUpdateMission: (Bool?, Bool?) async -> Void
  let onNavigateToSession: (String) -> Void

  @State private var isStartingOrchestrator = false
  @State private var actionError: String?
  @State private var expandedAgentId: String?

  private var isPolling: Bool {
    mission.orchestratorStatus == "polling"
  }

  private var runningIssues: [MissionIssueItem] {
    issues.running
  }

  private var failedIssues: [MissionIssueItem] {
    issues.failed
  }

  private var queuedIssues: [MissionIssueItem] {
    issues.queued
  }

  private var completedIssues: [MissionIssueItem] {
    issues.completed
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      // Setup flows + banners
      MissionSetupFlow(
        mission: mission,
        missionId: missionId,
        missionFileExists: missionFileExists,
        workflowMigrationAvailable: workflowMigrationAvailable,
        settings: settings,
        http: http,
        onApplyDetail: onApplyDetail,
        onRefresh: onRefresh,
        onSelectTab: onSelectTab
      )

      // Flight Strip
      MissionFlightStrip(
        mission: mission,
        nextTickAt: nextTickAt,
        lastTickAt: lastTickAt,
        isCompact: isCompact,
        onUpdateMission: onUpdateMission,
        onStartOrchestrator: startOrchestrator
      )

      // Hero Zone — state-driven content
      heroZone

      // Alert Board — only when failed issues exist
      if !failedIssues.isEmpty {
        MissionAlertBoard(
          failedIssues: failedIssues,
          missionId: missionId,
          endpointId: endpointId,
          http: http,
          onNavigateToSession: onNavigateToSession,
          onRefresh: onRefresh
        )
      }

      // Pipeline — queued + completed
      if !queuedIssues.isEmpty || !completedIssues.isEmpty {
        MissionPipeline(
          queuedIssues: queuedIssues,
          completedIssues: completedIssues,
          missionId: missionId,
          endpointId: endpointId,
          http: http,
          onNavigateToSession: onNavigateToSession,
          onRefresh: onRefresh,
          onSelectIssuesTab: { onSelectTab(.issues) }
        )
      }
    }
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  // MARK: - Hero Zone

  @ViewBuilder
  private var heroZone: some View {
    if !runningIssues.isEmpty {
      // In Flight — Agent Telemetry Cards
      agentDeck
    } else if isPolling && issues.isEmpty {
      // Scanning — countdown + standing by
      MissionScanningState(
        nextTickAt: nextTickAt,
        lastTickAt: lastTickAt,
        filterContext: filterContextString
      )
    } else if issues.isEmpty {
      // Docked — no issues at all
      MissionDockedState(
        mission: mission,
        onStartOrchestrator: startOrchestrator,
        onUpdateMission: onUpdateMission
      )
    }
    // When issues exist but none are running, the pipeline + alert board
    // are the content — no separate hero zone needed
  }

  // MARK: - Agent Deck

  private var agentDeck: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      MissionSectionHeader(
        title: "Active Agents",
        icon: "bolt.fill",
        color: Color.statusWorking,
        trailing: settings.map { "\(runningIssues.count) of \($0.provider.maxConcurrent)" }
      )

      let layout = isCompact
        ? AnyLayout(VStackLayout(spacing: Spacing.sm))
        : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.sm))

      layout {
        ForEach(runningIssues) { issue in
          MissionAgentCard(
            issue: issue,
            sessionStore: sessionStore,
            isCompact: isCompact,
            onNavigateToSession: onNavigateToSession,
            expandedIssueId: $expandedAgentId
          )
        }
      }
    }
  }

  // MARK: - Helpers

  private var filterContextString: String? {
    guard let settings else { return nil }
    var parts: [String] = []
    if let project = settings.trigger.filters.project, !project.isEmpty {
      parts.append("project: \(project)")
    }
    if let team = settings.trigger.filters.team, !team.isEmpty {
      parts.append("team: \(team)")
    }
    if !settings.trigger.filters.labels.isEmpty {
      parts.append("labels: \(settings.trigger.filters.labels.joined(separator: ", "))")
    }
    if !settings.trigger.filters.states.isEmpty {
      parts.append("states: \(settings.trigger.filters.states.joined(separator: ", "))")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: - Networking

  private func startOrchestrator() async {
    guard let http else { return }
    isStartingOrchestrator = true
    do {
      let _: MissionOkResponse = try await http.post(
        "/api/missions/\(missionId)/start-orchestrator",
        body: EmptyBody()
      )
    } catch {
      actionError = error.localizedDescription
    }
    isStartingOrchestrator = false
    await onRefresh()
  }
}
