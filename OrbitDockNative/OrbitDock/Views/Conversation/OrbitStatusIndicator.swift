//
//  OrbitStatusIndicator.swift
//  OrbitDock
//
//  Compact agent status strip at the bottom of the conversation timeline.
//  Shows on-brand orbital messaging with a subtle beacon pulse.
//
//  Performance note: The beacon glow uses a static radial gradient with
//  animated OPACITY only (compositing-only animation). This costs ~0ms/frame
//  because CA caches the gradient bitmap and just changes the blend factor.
//  The previous implementation animated .shadow() radius + .drawingGroup(),
//  which forced a full offscreen Metal render pass every frame (~5ms/frame,
//  50% CPU at idle).
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

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      Circle()
        .fill(statusColor)
        .frame(width: 5, height: 5)
      statusLabel
      Spacer()
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xs)
    .animation(Motion.gentle, value: displayStatus)
    .animation(Motion.gentle, value: currentTool)
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
