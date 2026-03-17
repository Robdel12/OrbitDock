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
  let onRefresh: () async -> Void
  let onApplyDetail: (MissionDetailResponse) -> Void
  let onSelectTab: (MissionTab) -> Void
  let onUpdateMission: (Bool?, Bool?) async -> Void
  let onNavigateToSession: (String) -> Void

  @State private var isStartingOrchestrator = false
  @State private var actionError: String?

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

      // Command Center
      MissionCommandCenter(
        mission: mission,
        settings: settings,
        isCompact: isCompact,
        onUpdateMission: onUpdateMission,
        onStartOrchestrator: startOrchestrator
      )

      // Active Threads
      if !runningIssues.isEmpty {
        MissionActiveThreads(
          runningIssues: runningIssues,
          missionId: missionId,
          settings: settings,
          isCompact: isCompact,
          sessionStore: sessionStore,
          http: http,
          onRefresh: onRefresh,
          onNavigateToSession: onNavigateToSession
        )
      }

      // Needs Attention
      if !failedIssues.isEmpty {
        attentionSection
      }

      // Queued
      if !queuedIssues.isEmpty {
        queueSection
      }

      // Completed
      if !completedIssues.isEmpty {
        completedSection
      }

      // Empty State
      if issues.isEmpty {
        waitingState
      }
    }
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  // MARK: - Attention Section

  private var attentionSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      MissionSectionHeader(
        title: "Needs Attention",
        icon: "exclamationmark.triangle.fill",
        color: Color.feedbackNegative,
        count: failedIssues.count
      )

      ForEach(failedIssues) { issue in
        MissionIssueRow(
          issue: issue,
          missionId: missionId,
          endpointId: endpointId,
          http: http,
          style: .compact,
          accentColor: Color.feedbackNegative,
          onNavigateToSession: onNavigateToSession,
          onRefresh: onRefresh
        )
      }
    }
  }

  // MARK: - Queue Section

  private var queueSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      MissionSectionHeader(
        title: "Queued",
        icon: "clock.fill",
        color: Color.feedbackCaution,
        count: queuedIssues.count
      )

      ForEach(queuedIssues) { issue in
        MissionIssueRow(
          issue: issue,
          missionId: missionId,
          endpointId: endpointId,
          http: http,
          style: .compact,
          accentColor: Color.feedbackCaution,
          onNavigateToSession: onNavigateToSession,
          onRefresh: onRefresh
        )
      }
    }
  }

  // MARK: - Completed Section

  private var completedSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      MissionSectionHeader(
        title: "Completed",
        icon: "checkmark.circle.fill",
        color: Color.feedbackPositive,
        count: completedIssues.count
      )

      ForEach(Array(completedIssues.prefix(5))) { issue in
        MissionIssueRow(
          issue: issue,
          missionId: missionId,
          endpointId: endpointId,
          http: http,
          style: .compact,
          accentColor: Color.feedbackPositive,
          onNavigateToSession: onNavigateToSession,
          onRefresh: onRefresh
        )
      }

      if completedIssues.count > 5 {
        Button {
          onSelectTab(.issues)
        } label: {
          HStack(spacing: Spacing.xs) {
            Text("View all \(completedIssues.count) completed")
              .font(.system(size: TypeScale.micro, weight: .medium))
            Image(systemName: "arrow.right")
              .font(.system(size: 8, weight: .bold))
          }
          .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
        .padding(.leading, Spacing.lg)
      }
    }
  }

  // MARK: - Waiting State

  private var waitingState: some View {
    let isPolling = mission.orchestratorStatus == "polling"
    let needsKey = mission.orchestratorStatus == "no_api_key"

    return VStack(spacing: Spacing.lg) {
      ZStack {
        Circle()
          .strokeBorder(
            (isPolling ? Color.accent : Color.textQuaternary).opacity(OpacityTier.subtle),
            lineWidth: 2
          )
          .frame(width: 56, height: 56)

        Circle()
          .strokeBorder(
            (isPolling ? Color.accent : Color.textQuaternary).opacity(OpacityTier.medium),
            lineWidth: 1.5
          )
          .frame(width: 36, height: 36)

        Image(systemName: isPolling ? "antenna.radiowaves.left.and.right" : needsKey ? "key" : "pause")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(isPolling ? Color.accent : Color.textQuaternary)
      }

      VStack(spacing: Spacing.sm_) {
        Text(waitingTitle)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textSecondary)

        Text(waitingSubtitle)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.xxl)
  }

  private var waitingTitle: String {
    switch mission.orchestratorStatus {
      case "polling": "Scanning for issues"
      case "no_api_key": "API key required"
      case "config_error": "Configuration error"
      case "paused": "Orchestrator paused"
      case "disabled": "Mission disabled"
      case "idle": "Ready to start"
      default: "Orchestrator not started"
    }
  }

  private var waitingSubtitle: String {
    switch mission.orchestratorStatus {
      case "polling":
        "The orchestrator is polling your tracker for matching issues. New issues will appear here automatically."
      case "no_api_key":
        "Set a Linear API key above or via the LINEAR_API_KEY environment variable, then start the orchestrator."
      case "config_error":
        "There's a problem with your MISSION.md configuration. Check the Settings tab for details."
      case "paused":
        "Resume the orchestrator to continue processing issues."
      case "disabled":
        "Enable the mission to start processing issues."
      case "idle":
        "Configuration looks good. Start the orchestrator to begin polling for issues."
      default:
        "Start the orchestrator to begin polling for issues."
    }
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
