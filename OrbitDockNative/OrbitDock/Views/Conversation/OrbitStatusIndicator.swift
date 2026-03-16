//
//  OrbitStatusIndicator.swift
//  OrbitDock
//
//  Compact agent status strip at the bottom of the conversation timeline.
//  Shows on-brand orbital messaging with rotating phrases and the
//  OrbitalAnimationLayer (CALayer-based, runs on the CA render server
//  with zero main-thread CPU cost).
//

import SwiftUI

struct OrbitStatusIndicator: View {
  let displayStatus: SessionDisplayStatus
  var currentTool: String?

  @State private var orbitPhrase = Self.orbitPhrases.randomElement() ?? "In orbit"

  private var title: String {
    switch displayStatus {
      case .working: orbitPhrase
      case .permission: "Holding pattern"
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

  private var statusColor: Color {
    displayStatus.color
  }

  private var orbitalState: OrbitalAnimationLayer.OrbitalState {
    switch displayStatus {
      case .working: .orbiting
      case .permission: .holding
      case .question: .holding
      case .reply: .parked
      case .ended: .hidden
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Color.surfaceBorder.opacity(0.4)
        .frame(height: 1)

      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm_) {
        OrbitalBeacon(state: orbitalState, color: statusColor)
          .frame(width: 16, height: 16)
          .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 1 }
        statusLabel
        Spacer()
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.xs)
    }
    .animation(Motion.gentle, value: displayStatus)
    .animation(Motion.gentle, value: currentTool)
    .onChange(of: currentTool) { _, _ in
      if displayStatus == .working {
        orbitPhrase = Self.orbitPhrases.randomElement() ?? "In orbit"
      }
    }
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

  // MARK: - Phrases

  private static let orbitPhrases = [
    "In orbit",
    "On approach",
    "Maneuvering",
    "Plotting course",
    "Engaging thrusters",
    "Locking on",
    "Running trajectory",
  ]
}

// MARK: - OrbitalBeacon (NSViewRepresentable bridge)

#if os(macOS)
  private final class OrbitalHostView: NSView {
    let orbital = OrbitalAnimationLayer()

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      orbital.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
      layer?.addSublayer(orbital)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError()
    }

    override func layout() {
      super.layout()
      orbital.frame = bounds
    }
  }

  private struct OrbitalBeacon: NSViewRepresentable {
    let state: OrbitalAnimationLayer.OrbitalState
    let color: Color

    func makeNSView(context: Context) -> OrbitalHostView {
      OrbitalHostView()
    }

    func updateNSView(_ nsView: OrbitalHostView, context: Context) {
      let cgColor = NSColor(color).cgColor
      let secondaryColor = NSColor(Color.composerSteer).cgColor
      nsView.orbital.configure(
        state: state,
        color: cgColor,
        secondaryColor: state == .orbiting ? secondaryColor : nil
      )
    }
  }
#else
  private final class OrbitalHostView: UIView {
    let orbital = OrbitalAnimationLayer()

    override init(frame: CGRect) {
      super.init(frame: frame)
      orbital.contentsScale = UIScreen.main.scale
      layer.addSublayer(orbital)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      orbital.frame = bounds
    }
  }

  private struct OrbitalBeacon: UIViewRepresentable {
    let state: OrbitalAnimationLayer.OrbitalState
    let color: Color

    func makeUIView(context: Context) -> OrbitalHostView {
      OrbitalHostView()
    }

    func updateUIView(_ uiView: OrbitalHostView, context: Context) {
      let cgColor = UIColor(color).cgColor
      uiView.orbital.configure(state: state, color: cgColor)
    }
  }
#endif

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
