import SwiftUI

/// Telemetry-style fleet status bar showing active fleet counts.
///
/// Uses monospaced digits with `.contentTransition(.numericText())` so count
/// changes spring-animate naturally. Status indicator lights (6pt dots) use
/// glow for urgent states.
///
/// Layout adapts to phoneCompact (tighter spacing) vs desktop (generous spacing).
struct FleetTelemetryStrip: View {
  let attentionCount: Int
  let orbitCount: Int
  let dockedCount: Int

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: layoutMode.isPhoneCompact ? Spacing.md : Spacing.lg) {
        if attentionCount > 0 {
          telemetryReadout(
            count: attentionCount,
            label: "incoming",
            color: .statusPermission,
            isUrgent: true
          )
        }

        telemetryReadout(
          count: orbitCount,
          label: "in orbit",
          color: .statusWorking
        )

        telemetryReadout(
          count: dockedCount,
          label: "docked",
          color: .statusReply
        )
      }

      Spacer()
    }
    .padding(.horizontal, layoutMode.isPhoneCompact ? Spacing.lg : Spacing.section)
    .padding(.vertical, Spacing.md)
  }

  private func telemetryReadout(
    count: Int,
    label: String,
    color: Color,
    isUrgent: Bool = false
  ) -> some View {
    HStack(spacing: Spacing.sm_) {
      // Status indicator light
      ZStack {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)

        if isUrgent {
          Circle()
            .fill(color.opacity(0.3))
            .frame(width: 12, height: 12)
        }
      }
      .frame(width: 14, height: 14)

      Text("\(count)")
        .font(.system(size: TypeScale.body, weight: .bold, design: .monospaced))
        .foregroundStyle(count > 0 ? Color.textPrimary : Color.textQuaternary)
        .contentTransition(.numericText())
        .animation(Motion.standard, value: count)

      Text(label)
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }
}

#Preview {
  VStack(spacing: 20) {
    FleetTelemetryStrip(attentionCount: 2, orbitCount: 5, dockedCount: 12)
    FleetTelemetryStrip(attentionCount: 0, orbitCount: 3, dockedCount: 8)
    FleetTelemetryStrip(attentionCount: 1, orbitCount: 0, dockedCount: 0)
  }
  .background(Color.backgroundPrimary)
  .preferredColorScheme(.dark)
}
