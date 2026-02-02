//
//  GenericUsageBar.swift
//  OrbitDock
//
//  Compact usage bar for any provider - used in headers and compact displays.
//

import SwiftUI

/// Compact progress bar showing utilization with optional label
struct GenericUsageBar: View {
  let window: RateLimitWindow
  let provider: Provider
  var showLabel: Bool = true

  private var progressColor: Color {
    provider.color(for: window.utilization)
  }

  private var helpText: String {
    var text = "\(window.label): \(Int(window.utilization))% used"
    if let resets = window.resetsInDescription {
      text += " • resets in \(resets)"
    }
    return text
  }

  var body: some View {
    HStack(spacing: 5) {
      if showLabel {
        Text(window.label)
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.tertiary)
      }

      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(0.08))

          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(progressColor)
            .frame(width: geo.size.width * min(1, window.utilization / 100))
        }
      }
      .frame(width: 28, height: 4)

      Text("\(Int(window.utilization))%")
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(progressColor)
    }
    .help(helpText)
  }
}

#Preview {
  VStack(spacing: 16) {
    GenericUsageBar(
      window: .fiveHour(utilization: 45, resetsAt: Date().addingTimeInterval(3600)),
      provider: .claude
    )
    GenericUsageBar(
      window: .fiveHour(utilization: 75, resetsAt: Date().addingTimeInterval(1800)),
      provider: .codex
    )
  }
  .padding()
  .background(Color.backgroundSecondary)
}
