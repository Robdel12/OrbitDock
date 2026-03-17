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
    let running = UInt32(issues.running.count)
    let queued = UInt32(issues.queued.count)
    let completed = UInt32(issues.completed.count)
    let failed = UInt32(issues.failed.count)

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
        if running > 0 { MissionStatChip(count: running, label: "running", color: .statusWorking) }
        if queued > 0 { MissionStatChip(count: queued, label: "queued", color: .feedbackCaution) }
        if failed > 0 { MissionStatChip(count: failed, label: "failed", color: .feedbackNegative) }
        if completed > 0 { MissionStatChip(count: completed, label: "done", color: .feedbackPositive) }
      }
    }
  }

  // MARK: - Pipeline

  private var pipelineContent: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      let running = issues.running
      let queued = issues.queued
      let failed = issues.failed
      let completed = issues.completed

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
      .cosmicCard(cornerRadius: Radius.ml, fillColor: .backgroundSecondary, fillOpacity: 1.0, borderColor: color)
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
