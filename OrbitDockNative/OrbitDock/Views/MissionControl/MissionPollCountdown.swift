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
        Text("Next poll in \(formatRemaining(remaining))")
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.accent)
      }
    } else if let last = lastTickAt {
      let elapsed = Int(now.timeIntervalSince(last))
      HStack(spacing: Spacing.xs) {
        Image(systemName: "clock")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(Color.textTertiary)
        Text("Last polled \(formatElapsed(elapsed))")
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  private func formatRemaining(_ seconds: Int) -> String {
    if seconds >= 60 {
      let m = seconds / 60
      let s = seconds % 60
      return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
    return "\(seconds)s"
  }

  private func formatElapsed(_ seconds: Int) -> String {
    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3600)h ago"
  }
}
