//
//  GenericMenuBarGauge.swift
//  OrbitDock
//
//  Horizontal progress gauge for menu bar usage sections.
//

import SwiftUI

/// Horizontal gauge with label, progress bar, and projections for menu bar display
struct GenericMenuBarGauge: View {
  let window: RateLimitWindow
  let provider: Provider
  @Environment(\.colorScheme) private var colorScheme

  /// Show day for multi-day windows
  private var showDay: Bool {
    window.windowDuration > 24 * 3_600
  }

  /// Color for reset time based on urgency
  private var resetTimeColor: Color {
    if window.timeRemaining < 15 * 60 { return .statusError }
    if window.timeRemaining < 60 * 60 { return .statusWaiting }
    return subtleLabelColor
  }

  /// Projected usage color
  private var projectedColor: Color {
    let projected = window.projectedAtReset
    if projected > 100 { return .statusError }
    if projected > 90 { return .statusWaiting }
    return .statusSuccess
  }

  private var color: Color {
    provider.color(for: window.utilization)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      // Label row
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(windowLabel)
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(secondaryLabelColor)

        // Warning if will exceed
        if window.willExceed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.statusError)
        }

        if let resetTime = window.resetsAtFormatted(showDay: showDay) {
          Text("• \(resetTime)")
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(resetTimeColor)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }

        Spacer()

        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text("\(Int(window.utilization))%")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)

          // Projected usage
          if window.projectedAtReset > window.utilization + 5 {
            Text("→ \(Int(window.projectedAtReset.rounded()))%")
              .font(.system(size: 10, weight: .bold, design: .rounded))
              .foregroundStyle(projectedColor)
          }
        }
      }

      // Progress bar with projection
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(trackColor)

          // Projected usage (more visible)
          if window.projectedAtReset > window.utilization {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(projectedColor.opacity(window.willExceed ? 0.5 : 0.35))
              .frame(width: geo.size.width * min(1, window.projectedAtReset / 100))
          }

          // Current usage
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: geo.size.width * min(1, window.utilization / 100))
        }
      }
      .frame(height: 6)
    }
  }

  private var secondaryLabelColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.68) : .primary.opacity(0.74)
  }

  private var subtleLabelColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.52) : .primary.opacity(0.62)
  }

  private var trackColor: Color {
    Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.14)
  }

  /// Convert label to more descriptive form for menu bar
  private var windowLabel: String {
    // If the window label is just a duration code, expand it
    switch window.label {
      case "5h": return "5h Session"
      case "7d": return "7d Rolling"
      default:
        // For Codex-style labels like "15m", "1h"
        if window.label.hasSuffix("m") || window.label.hasSuffix("h") {
          return "\(window.label) window"
        }
        return window.label
    }
  }
}

#Preview {
  VStack(spacing: 12) {
    GenericMenuBarGauge(
      window: .fiveHour(utilization: 45, resetsAt: Date().addingTimeInterval(3_600)),
      provider: .claude
    )
    GenericMenuBarGauge(
      window: .sevenDay(utilization: 75, resetsAt: Date().addingTimeInterval(86_400)),
      provider: .claude
    )
    GenericMenuBarGauge(
      window: .fromMinutes(id: "primary", utilization: 30, windowMinutes: 15, resetsAt: Date().addingTimeInterval(600)),
      provider: .codex
    )
  }
  .padding()
  .frame(width: 260)
  .background(Color.backgroundPrimary)
}
