//
//  OrbitStatusIndicator.swift
//  OrbitDock
//
//  Compact agent status strip at the bottom of the conversation timeline.
//  Shows on-brand orbital messaging with a subtle beacon pulse.
//

import SwiftUI

struct OrbitStatusIndicator: View {
  let displayStatus: SessionDisplayStatus
  var currentTool: String?

  private var title: String {
    switch displayStatus {
    case .working: "In Orbit"
    case .permission: "Beacon Detected"
    case .question: "Hailing Frequencies"
    case .reply: "Docked"
    case .ended: "Mission Complete"
    }
  }

  private var detail: String? {
    switch displayStatus {
    case .working:
      currentTool.map { "Running \($0)" }
    case .permission:
      "Awaiting clearance"
    case .question:
      "Standing by for response"
    case .reply:
      "Ready for next mission"
    case .ended:
      nil
    }
  }

  private var statusColor: Color { displayStatus.color }

  private var isAnimated: Bool {
    displayStatus != .ended
  }

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      beacon
      statusLabel
      Spacer()
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xs)
    .animation(Motion.gentle, value: displayStatus)
    .animation(Motion.gentle, value: currentTool)
  }

  // MARK: - Beacon

  @ViewBuilder
  private var beacon: some View {
    if isAnimated {
      PhaseAnimator(BeaconPhase.allCases) { phase in
        beaconDot(glowOpacity: phase.glowOpacity, glowRadius: phase.glowRadius)
      } animation: { phase in
        switch phase {
        case .rest: .easeIn(duration: 0.8)
        case .glow: .easeOut(duration: 1.0)
        case .peak: .easeInOut(duration: 0.6)
        }
      }
    } else {
      beaconDot(glowOpacity: 0.2, glowRadius: 1)
    }
  }

  private func beaconDot(glowOpacity: Double, glowRadius: CGFloat) -> some View {
    Circle()
      .fill(statusColor)
      .frame(width: 5, height: 5)
      .shadow(color: statusColor.opacity(glowOpacity), radius: glowRadius)
      .drawingGroup()
  }

  // MARK: - Label

  private var statusLabel: some View {
    HStack(spacing: Spacing.xs) {
      Text(title)
        .font(.system(size: TypeScale.meta, weight: .semibold))
        .foregroundStyle(statusColor)
        .contentTransition(.interpolate)

      if let detail {
        Text("·")
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(Color.textQuaternary)

        Text(detail)
          .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .contentTransition(.interpolate)
      }
    }
  }
}

// MARK: - Beacon Animation Phases

private enum BeaconPhase: CaseIterable {
  case rest, glow, peak

  var glowOpacity: Double {
    switch self {
    case .rest: 0.25
    case .glow: 0.65
    case .peak: 0.4
    }
  }

  var glowRadius: CGFloat {
    switch self {
    case .rest: 1.5
    case .glow: 4
    case .peak: 2.5
    }
  }
}

// MARK: - Preview

#Preview("All States") {
  VStack(spacing: 0) {
    OrbitStatusIndicator(displayStatus: .working, currentTool: "Edit")
    OrbitStatusIndicator(displayStatus: .working)
    OrbitStatusIndicator(displayStatus: .permission)
    OrbitStatusIndicator(displayStatus: .question)
    OrbitStatusIndicator(displayStatus: .reply)
    OrbitStatusIndicator(displayStatus: .ended)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 500)
}
