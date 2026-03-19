import SwiftUI

struct MissionScanningState: View {
  let nextTickAt: Date?
  let lastTickAt: Date?
  let filterContext: String?

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Spacer()

      // Orbital animation
      orbitalAnimation
        .frame(width: 80, height: 60)

      Text("Standing By")
        .font(.system(size: TypeScale.title, weight: .semibold))
        .foregroundStyle(Color.textSecondary)

      // Large countdown
      countdownLabel

      if let filterContext, !filterContext.isEmpty {
        Text("Watching for issues matching: \(filterContext)")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .multilineTextAlignment(.center)
      }

      Spacer()
    }
    .padding(.vertical, Spacing.xxl)
  }

  // MARK: - Countdown Label

  private var countdownLabel: some View {
    TimelineView(.periodic(from: .now, by: 1.0)) { context in
      let now = context.date
      if let next = nextTickAt, next > now {
        let remaining = Int(next.timeIntervalSince(now))
        Text("Next scan in \(formatRemaining(remaining))")
          .font(.system(size: TypeScale.subhead, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.accent)
      } else if let last = lastTickAt {
        let elapsed = Int(now.timeIntervalSince(last))
        Text("Last scan \(formatElapsed(elapsed))")
          .font(.system(size: TypeScale.subhead, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      } else {
        Text("Waiting for first scan")
          .font(.system(size: TypeScale.subhead, weight: .medium))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  // MARK: - Orbital Animation

  private var orbitalAnimation: some View {
    TimelineView(.periodic(from: .now, by: 0.03)) { context in
      let elapsed = context.date.timeIntervalSinceReferenceDate
      let angle = elapsed.truncatingRemainder(dividingBy: 6.0) / 6.0 * 2 * .pi

      Canvas { ctx, size in
        let cx = size.width / 2
        let cy = size.height / 2
        let rx: CGFloat = 30
        let ry: CGFloat = 20

        // Draw trailing fade (3 trailing dots)
        for i in stride(from: 3, through: 1, by: -1) {
          let trailAngle = angle - Double(i) * 0.15
          let tx = cx + rx * cos(trailAngle)
          let ty = cy + ry * sin(trailAngle)
          let opacity = OpacityTier.light * (1.0 - Double(i) * 0.25)
          let trailSize: CGFloat = 4.0 - CGFloat(i) * 0.6

          ctx.fill(
            Path(ellipseIn: CGRect(
              x: tx - trailSize / 2,
              y: ty - trailSize / 2,
              width: trailSize,
              height: trailSize
            )),
            with: .color(Color.accent.opacity(opacity))
          )
        }

        // Draw main dot
        let dx = cx + rx * cos(angle)
        let dy = cy + ry * sin(angle)
        ctx.fill(
          Path(ellipseIn: CGRect(x: dx - 2, y: dy - 2, width: 4, height: 4)),
          with: .color(Color.accent)
        )
      }
    }
  }

  // MARK: - Formatting

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
