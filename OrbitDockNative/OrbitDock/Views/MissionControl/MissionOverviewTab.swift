import SwiftUI

struct MissionOverviewTab: View {
  let mission: MissionSummary
  let cleanupPrompt: MissionCleanupPrompt?
  let settings: MissionSettings?
  let issues: [MissionIssueItem]
  let missionId: String
  let missionFileExists: Bool
  let workflowMigrationAvailable: Bool
  let http: ServerHTTPClient?
  let isCompact: Bool
  let endpointId: UUID
  let nextTickAt: Date?
  let lastTickAt: Date?
  let onRefresh: () async -> Void
  let onApplyDetail: (MissionDetailResponse) -> Void
  let onShowCleanup: () -> Void
  let onSelectTab: (MissionTab) -> Void
  let onUpdateMission: (Bool?, Bool?) async -> Void
  let onNavigateToSession: (String) -> Void
  let onTransitionIssue: (String, OrchestrationState, String?) async -> Void

  @State private var isStartingOrchestrator = false
  @State private var actionError: String?
  private var isPolling: Bool {
    mission.orchestratorStatus == "polling"
  }

  private var runningIssues: [MissionIssueItem] {
    issues.running
  }

  private var sortedIssues: [MissionIssueItem] {
    issues.sorted { lhs, rhs in
      let lhsStatus = displayStatus(for: lhs)
      let rhsStatus = displayStatus(for: rhs)
      let lhsPriority = lhsStatus?.sortPriority ?? 5
      let rhsPriority = rhsStatus?.sortPriority ?? 5
      if lhsPriority != rhsPriority {
        return lhsPriority < rhsPriority
      }

      let lhsDate = sortDate(for: lhs)
      let rhsDate = sortDate(for: rhs)
      if lhsDate != rhsDate {
        return lhsDate > rhsDate
      }

      return lhs.identifier.localizedCaseInsensitiveCompare(rhs.identifier) == .orderedAscending
    }
  }

  private var needsAttentionIssues: [MissionIssueItem] {
    sortedIssues.filter { issue in
      switch issue.orchestrationState {
        case .blocked, .failed:
          true
        default:
          displayStatus(for: issue)?.needsAttention == true
      }
    }
  }

  private var inFlightIssues: [MissionIssueItem] {
    sortedIssues.filter { issue in
      issue.orchestrationState == .running || issue.orchestrationState == .claimed
    }
  }

  private var queuedIssues: [MissionIssueItem] {
    sortedIssues.filter {
      $0.orchestrationState == .queued || $0.orchestrationState == .retryQueued
    }
  }

  private var completedIssues: [MissionIssueItem] {
    sortedIssues.filter { $0.orchestrationState == .completed }
  }

  private var lingeringWorktreeCount: UInt32 {
    cleanupPrompt?.lingeringWorktreeCount ?? 0
  }

  private var blockedCount: UInt32 {
    UInt32(issues.blocked.count + issues.failed.count)
  }

  private var readyAgentCount: UInt32 {
    UInt32(inFlightIssues.filter { displayStatus(for: $0) == .reply }.count)
  }

  private var pullRequestCount: UInt32 {
    UInt32(issues.filter { $0.prUrl != nil }.count)
  }

  private var recentlyShippedIssues: [MissionIssueItem] {
    Array(completedIssues.prefix(isCompact ? 3 : 4))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: isCompact ? Spacing.lg : Spacing.xl) {
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

      // Command Bar
      MissionFlightStrip(
        mission: mission,
        nextTickAt: nextTickAt,
        lastTickAt: lastTickAt,
        isCompact: isCompact,
        onUpdateMission: onUpdateMission,
        onStartOrchestrator: startOrchestrator,
        onTriggerPoll: triggerPoll
      )

      if lingeringWorktreeCount > 0 {
        MissionCleanupBanner(
          lingeringWorktreeCount: lingeringWorktreeCount,
          onReviewCleanup: onShowCleanup
        )
      }

      overviewBoard
    }
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  // MARK: - Overview Board

  @ViewBuilder
  private var overviewBoard: some View {
    if issues.isEmpty, isPolling {
      MissionScanningState(
        nextTickAt: nextTickAt,
        lastTickAt: lastTickAt,
        filterContext: filterContextString
      )
    } else if issues.isEmpty {
      MissionDockedState(
        mission: mission,
        onStartOrchestrator: startOrchestrator,
        onUpdateMission: onUpdateMission
      )
    } else {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        overviewSummaryBar

        if !needsAttentionIssues.isEmpty {
          overviewSection(
            title: "Needs You",
            icon: "exclamationmark.triangle.fill",
            color: Color.statusPermission,
            subtitle: "Approvals, questions, failures, and blocked work bubble to the top.",
            issues: needsAttentionIssues
          )
        }

        if !inFlightIssues.isEmpty {
          overviewSection(
            title: "In Flight",
            icon: "bolt.fill",
            color: Color.statusWorking,
            subtitle: "Active issue threads with live agent progress and tracker context.",
            issues: inFlightIssues
          )
        }

        if !queuedIssues.isEmpty {
          overviewSection(
            title: "Queued Next",
            icon: "clock.fill",
            color: Color.feedbackCaution,
            subtitle: "What the orchestrator will pick up after the current flight lane clears.",
            issues: queuedIssues
          )
        }

        if !recentlyShippedIssues.isEmpty {
          overviewSection(
            title: "Recently Shipped",
            icon: "checkmark.circle.fill",
            color: Color.feedbackPositive,
            subtitle: "Recent wins, including linked pull requests when we have them.",
            issues: recentlyShippedIssues,
            footer: {
              if completedIssues.count > recentlyShippedIssues.count {
                Button {
                  onSelectTab(.issues)
                } label: {
                  Label("View all completed work", systemImage: "arrow.right")
                    .font(.system(size: TypeScale.micro, weight: .semibold))
                    .foregroundStyle(Color.accent)
                }
                .buttonStyle(.plain)
              }
            }
          )
        }
      }
    }
  }

  private var overviewSummaryBar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Spacing.lg) {
        HStack(spacing: Spacing.sm_) {
          Text("\(issues.count)")
            .font(.system(size: TypeScale.body, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.textPrimary)
          Text("tracked")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
        }

        Spacer(minLength: 0)

        HStack(spacing: Spacing.md) {
          if !runningIssues.isEmpty { MissionStatChip(
            count: UInt32(runningIssues.count),
            label: "running",
            color: .statusWorking
          ) }
          if blockedCount > 0 { MissionStatChip(
            count: blockedCount,
            label: "attention",
            color: .statusPermission,
            style: .icon("exclamationmark.triangle.fill")
          ) }
          if !queuedIssues.isEmpty { MissionStatChip(
            count: UInt32(queuedIssues.count),
            label: "queued",
            color: .feedbackCaution
          ) }
          if readyAgentCount > 0 { MissionStatChip(
            count: readyAgentCount,
            label: "ready",
            color: .statusReply,
            style: .icon("bubble.left")
          ) }
          if pullRequestCount > 0 { MissionStatChip(
            count: pullRequestCount,
            label: "prs",
            color: .accent,
            style: .icon("arrow.triangle.pull")
          ) }
          if !completedIssues.isEmpty { MissionStatChip(
            count: UInt32(completedIssues.count),
            label: "done",
            color: .feedbackPositive
          ) }
        }
      }

      WrappingFlowLayout(spacing: Spacing.sm) {
        MissionStatChip(count: UInt32(issues.count), label: "tracked", color: .textSecondary, style: .icon("number"))
        if !runningIssues.isEmpty { MissionStatChip(
          count: UInt32(runningIssues.count),
          label: "running",
          color: .statusWorking
        ) }
        if blockedCount > 0 { MissionStatChip(
          count: blockedCount,
          label: "attention",
          color: .statusPermission,
          style: .icon("exclamationmark.triangle.fill")
        ) }
        if !queuedIssues.isEmpty { MissionStatChip(
          count: UInt32(queuedIssues.count),
          label: "queued",
          color: .feedbackCaution
        ) }
        if readyAgentCount > 0 {
          MissionStatChip(count: readyAgentCount, label: "ready", color: .statusReply, style: .icon("bubble.left"))
        }
        if pullRequestCount > 0 {
          MissionStatChip(count: pullRequestCount, label: "prs", color: .accent, style: .icon("arrow.triangle.pull"))
        }
        if !completedIssues.isEmpty {
          MissionStatChip(count: UInt32(completedIssues.count), label: "done", color: .feedbackPositive)
        }
      }
    }
  }

  private func displayStatus(for issue: MissionIssueItem) -> SessionDisplayStatus? {
    switch issue.workStatus {
      case "permission":
        .permission
      case "question":
        .question
      case "working":
        .working
      case "reply", "waiting":
        .reply
      case nil:
        nil
      default:
        nil
    }
  }

  private func sortDate(for issue: MissionIssueItem) -> Date {
    parseTimestamp(issue.lastActivity)
      ?? parseTimestamp(issue.startedAt)
      ?? parseTimestamp(issue.completedAt)
      ?? .distantPast
  }

  private func issueRowAccent(for issue: MissionIssueItem) -> Color {
    if issue.orchestrationState == .failed || issue.orchestrationState == .blocked {
      return issue.orchestrationState.color
    }
    return displayStatus(for: issue)?.color ?? issue.orchestrationState.color
  }

  private func parseTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    return MissionOverviewTimestampParser.shared.date(from: value)
  }

  private func overviewSection(
    title: String,
    icon: String,
    color: Color,
    subtitle: String,
    issues: [MissionIssueItem],
    @ViewBuilder footer: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)

          Text(title)
            .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .tracking(0.3)

          Text("\(issues.count)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, 1)
            .background(
              color.opacity(OpacityTier.subtle),
              in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            )
        }

        if !isCompact {
          Text(subtitle)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
        }
      }

      VStack(spacing: 1) {
        ForEach(issues) { issue in
          MissionIssueRow(
            issue: issue,
            missionId: missionId,
            endpointId: endpointId,
            http: http,
            style: .full,
            isCompact: isCompact,
            accentColor: issueRowAccent(for: issue),
            onNavigateToSession: onNavigateToSession,
            onRefresh: onRefresh,
            onTransitionIssue: onTransitionIssue
          )
        }
      }
      .cosmicCard(cornerRadius: Radius.ml, fillColor: .backgroundSecondary, fillOpacity: 1.0, borderColor: color)

      footer()
    }
  }

  private func overviewSection(
    title: String,
    icon: String,
    color: Color,
    subtitle: String,
    issues: [MissionIssueItem]
  ) -> some View {
    overviewSection(
      title: title,
      icon: icon,
      color: color,
      subtitle: subtitle,
      issues: issues
    ) {
      EmptyView()
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
    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
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

  private func triggerPoll() async {
    guard let http else { return }
    do {
      let _: MissionOkResponse = try await http.post(
        "/api/missions/\(missionId)/trigger",
        body: EmptyBody()
      )
    } catch {
      actionError = error.localizedDescription
    }
  }

  private func endAgentSession(_ sessionId: String) async {
    guard let http else { return }
    do {
      let _: ServerAcceptedResponse = try await http.post(
        "/api/sessions/\(sessionId)/end",
        body: EmptyBody()
      )
      await onRefresh()
    } catch {
      actionError = error.localizedDescription
    }
  }
}

private final class MissionOverviewTimestampParser {
  static let shared = MissionOverviewTimestampParser()

  private let fractionalFormatter: ISO8601DateFormatter
  private let standardFormatter: ISO8601DateFormatter

  private init() {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.fractionalFormatter = fractionalFormatter

    let standardFormatter = ISO8601DateFormatter()
    standardFormatter.formatOptions = [.withInternetDateTime]
    self.standardFormatter = standardFormatter
  }

  func date(from value: String) -> Date? {
    fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
  }
}

private struct MissionCleanupBanner: View {
  let lingeringWorktreeCount: UInt32
  let onReviewCleanup: () -> Void

  private var titleText: String {
    lingeringWorktreeCount == 1
      ? "1 mission worktree is still on disk"
      : "\(lingeringWorktreeCount) mission worktrees are still on disk"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "externaldrive.badge.exclamationmark")
          .font(.system(size: IconScale.sm, weight: .semibold))
          .foregroundStyle(Color.feedbackCaution)
          .frame(width: 28, height: 28)
          .background(
            Color.feedbackCaution.opacity(OpacityTier.subtle),
            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          )

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(titleText)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text("OrbitDock leaves mission worktrees in place until you review them. Clean up when you're ready.")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: Spacing.md)

        Button("Review Cleanup") {
          onReviewCleanup()
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.statusPermission)
        .controlSize(.small)
      }
    }
    .padding(Spacing.lg)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.feedbackCaution.opacity(OpacityTier.medium), lineWidth: 1)
    )
  }
}
