import SwiftUI

struct MissionIssuesTab: View {
  let issues: [MissionIssueItem]
  let missionId: String
  let endpointId: UUID
  let http: ServerHTTPClient?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      if issues.isEmpty {
        emptyState
      } else {
        issuesSummaryBar
        pipelineContent
      }
    }
  }

  // MARK: - Summary Bar

  private var issuesSummaryBar: some View {
    let running = issues.filter { $0.orchestrationState == .running || $0.orchestrationState == .claimed }.count
    let queued = issues.filter { $0.orchestrationState == .queued || $0.orchestrationState == .retryQueued }.count
    let completed = issues.filter { $0.orchestrationState == .completed }.count
    let failed = issues.filter { $0.orchestrationState == .failed }.count

    return HStack(spacing: Spacing.lg) {
      HStack(spacing: Spacing.sm_) {
        Text("\(issues.count)")
          .font(.system(size: TypeScale.body, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
        Text("total")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textTertiary)
      }

      Spacer()

      HStack(spacing: Spacing.md) {
        if running > 0 { miniStat("\(running) running", color: Color.statusWorking) }
        if queued > 0 { miniStat("\(queued) queued", color: Color.feedbackCaution) }
        if failed > 0 { miniStat("\(failed) failed", color: Color.feedbackNegative) }
        if completed > 0 { miniStat("\(completed) done", color: Color.feedbackPositive) }
      }
    }
  }

  private func miniStat(_ text: String, color: Color) -> some View {
    HStack(spacing: Spacing.xs) {
      Circle()
        .fill(color)
        .frame(width: 5, height: 5)
      Text(text)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(color)
    }
  }

  // MARK: - Pipeline

  private var pipelineContent: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      let running = issues.filter { $0.orchestrationState == .running || $0.orchestrationState == .claimed }
      let queued = issues.filter { $0.orchestrationState == .queued || $0.orchestrationState == .retryQueued }
      let failed = issues.filter { $0.orchestrationState == .failed }
      let completed = issues.filter { $0.orchestrationState == .completed }

      if !running.isEmpty {
        issueGroup("Running", count: running.count, color: Color.statusWorking, icon: "bolt.fill", issues: running)
      }
      if !queued.isEmpty {
        issueGroup("Queued", count: queued.count, color: Color.feedbackCaution, icon: "clock.fill", issues: queued)
      }
      if !failed.isEmpty {
        issueGroup(
          "Failed",
          count: failed.count,
          color: Color.feedbackNegative,
          icon: "xmark.circle.fill",
          issues: failed
        )
      }
      if !completed.isEmpty {
        issueGroup(
          "Completed",
          count: completed.count,
          color: Color.feedbackPositive,
          icon: "checkmark.circle.fill",
          issues: completed
        )
      }
    }
  }

  private func issueGroup(
    _ title: String,
    count: Int,
    color: Color,
    icon: String,
    issues: [MissionIssueItem]
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(color)

        Text(title)
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textSecondary)

        Text("\(count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
          .foregroundStyle(color)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 1)
          .background(
            color.opacity(OpacityTier.subtle),
            in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          )
      }
      .padding(.leading, Spacing.sm_)

      VStack(spacing: 1) {
        ForEach(issues) { issue in
          MissionIssueRow(
            issue: issue,
            missionId: missionId,
            endpointId: endpointId,
            http: http
          )
        }
      }
      .background(
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .fill(Color.backgroundSecondary)
      )
      .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .strokeBorder(color.opacity(OpacityTier.subtle), lineWidth: 1)
      )
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    MissionEmptyState(
      icon: "tray",
      title: "No issues tracked yet",
      subtitle: "Issues matching your trigger filters will appear here as the orchestrator polls your tracker."
    )
  }
}
