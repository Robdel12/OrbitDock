import SwiftUI

struct MissionPollCountdown: View {
  let nextTickAt: Date?
  let lastTickAt: Date?
  let isPolling: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1.0)) { context in
      let now = context.date
      countdownContent(now: now)
    }
  }

  @ViewBuilder
  private func countdownContent(now: Date) -> some View {
    if isPolling, let next = nextTickAt, next > now {
      let remaining = Int(next.timeIntervalSince(now))
      HStack(spacing: Spacing.xs) {
        Image(systemName: "timer")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(Color.accent)
        Text("Next poll in \(DashboardFormatters.remaining(remaining))")
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.accent)
      }
    } else if let last = lastTickAt {
      let elapsed = Int(now.timeIntervalSince(last))
      HStack(spacing: Spacing.xs) {
        Image(systemName: "clock")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(Color.textTertiary)
        Text("Last polled \(DashboardFormatters.elapsed(elapsed))")
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }
}
