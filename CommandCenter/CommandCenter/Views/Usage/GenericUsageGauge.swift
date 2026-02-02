//
//  GenericUsageGauge.swift
//  OrbitDock
//
//  Circular gauge for usage display - used in dashboard cards.
//

import SwiftUI

/// Circular gauge showing utilization with projected usage and pace indicator
struct GenericUsageGauge: View {
  let window: RateLimitWindow
  let provider: Provider
  var size: CGFloat = 44
  var lineWidth: CGFloat = 4

  private var color: Color {
    provider.color(for: window.utilization)
  }

  private var paceColor: Color {
    window.paceStatus.color
  }

  /// Show day for multi-day windows
  private var showDay: Bool {
    window.windowDuration > 24 * 3600
  }

  var body: some View {
    VStack(spacing: 4) {
      ZStack {
        // Background ring
        Circle()
          .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)

        // Projected usage indicator (faint)
        if window.projectedAtReset > window.utilization {
          Circle()
            .trim(from: min(1, window.utilization / 100), to: min(1, window.projectedAtReset / 100))
            .stroke(
              paceColor.opacity(0.25),
              style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
        }

        // Progress arc
        Circle()
          .trim(from: 0, to: min(1, window.utilization / 100))
          .stroke(
            color,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))

        // Center value
        Text("\(Int(window.utilization))")
          .font(.system(size: 13, weight: .bold, design: .rounded))
          .foregroundStyle(color)
      }
      .frame(width: size, height: size)

      // Label + reset time
      VStack(spacing: 2) {
        Text(window.label)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)

        if let resetTime = window.resetsAtFormatted(showDay: showDay) {
          Text("@ \(resetTime)")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .overlay(alignment: .topTrailing) {
      // Pace indicator badge
      if window.paceStatus != .unknown {
        Image(systemName: window.paceStatus.icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(paceColor)
          .padding(2)
          .background(Color.backgroundTertiary, in: Circle())
          .offset(x: 4, y: -2)
      }
    }
  }
}

#Preview {
  HStack(spacing: 20) {
    GenericUsageGauge(
      window: .fiveHour(utilization: 45, resetsAt: Date().addingTimeInterval(3600)),
      provider: .claude
    )
    GenericUsageGauge(
      window: .sevenDay(utilization: 65, resetsAt: Date().addingTimeInterval(86400)),
      provider: .claude
    )
    GenericUsageGauge(
      window: .fromMinutes(id: "primary", utilization: 30, windowMinutes: 15, resetsAt: Date().addingTimeInterval(600)),
      provider: .codex
    )
  }
  .padding()
  .background(Color.backgroundPrimary)
}
