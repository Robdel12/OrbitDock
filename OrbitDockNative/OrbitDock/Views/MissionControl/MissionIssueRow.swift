import SwiftUI

struct MissionIssueRow: View {
  let issue: MissionIssueItem

  var body: some View {
    HStack(spacing: Spacing.md) {
      stateIcon
        .frame(width: 20)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.sm_) {
          Text(issue.identifier)
            .font(.system(size: TypeScale.caption, weight: .bold))
            .foregroundStyle(Color.textTertiary)

          Text(issue.title)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
        }

        HStack(spacing: Spacing.sm) {
          Text(issue.trackerState)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)

          if issue.attempt > 1 {
            Text("Attempt \(issue.attempt)")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(.orange)
          }

          if let activity = issue.lastActivity {
            Text(activity)
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
          }
        }
      }

      Spacer()

      if let error = issue.error {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(Color.statusError)
          .help(error)
      }
    }
    .padding(.vertical, Spacing.sm_)
  }

  @ViewBuilder
  private var stateIcon: some View {
    switch issue.orchestrationState {
    case .queued:
      Image(systemName: "clock")
        .foregroundStyle(Color.textTertiary)
    case .claimed:
      Image(systemName: "arrow.right.circle")
        .foregroundStyle(.blue)
    case .running:
      Image(systemName: "play.circle.fill")
        .foregroundStyle(.blue)
    case .retryQueued:
      Image(systemName: "arrow.clockwise.circle")
        .foregroundStyle(.orange)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.feedbackPositive)
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(Color.statusError)
    }
  }
}
