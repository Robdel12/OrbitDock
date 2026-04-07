import SwiftUI

/// The signature visual element of OrbitDock.
///
/// A small animated ring that communicates session status through motion and light.
/// Motion IS the message — each status has a distinct movement pattern recognizable
/// even in peripheral vision:
///
/// - **Working**: Orbiting arc (satellite in motion) — smooth, continuous rotation
/// - **Permission/Question**: Pulsing radar ping — outward ripple demanding attention
/// - **Reply**: Static ring with center dot — calm, docked, waiting
/// - **Ended**: Faint ring, no animation — dormant
struct OrbitalStatusIndicator: View {
  let status: SessionDisplayStatus
  var size: CGFloat = 14

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var orbitRotation: Double = 0
  @State private var pulsePhase: CGFloat = 0

  var body: some View {
    if reduceMotion {
      staticIndicator
    } else {
      animatedIndicator
    }
  }

  /// Reduced motion fallback — static colored dot with ring.
  private var staticIndicator: some View {
    ZStack {
      Circle()
        .strokeBorder(status.color.opacity(baseRingOpacity), lineWidth: size > 16 ? 1.5 : 1)
        .frame(width: size, height: size)

      Circle()
        .fill(status.color.opacity(status == .ended ? 0.25 : 0.6))
        .frame(width: size * 0.35, height: size * 0.35)
    }
    .shadow(color: status.color.opacity(glowIntensity), radius: glowRadius)
    .frame(width: size + 4, height: size + 4)
  }

  /// Full animated indicator.
  private var animatedIndicator: some View {
    ZStack {
      Circle()
        .strokeBorder(
          status.color.opacity(baseRingOpacity),
          lineWidth: size > 16 ? 1.5 : 1
        )
        .frame(width: size, height: size)

      statusOverlay
    }
    .shadow(color: status.color.opacity(glowIntensity), radius: glowRadius)
    .frame(width: size + 4, height: size + 4)
  }

  // MARK: - Status-Specific Overlays

  @ViewBuilder
  private var statusOverlay: some View {
    switch status {
    case .working:
      workingOverlay
    case .permission, .question:
      attentionOverlay
    case .reply:
      replyOverlay
    case .ended:
      endedOverlay
    }
  }

  /// Orbiting satellite arc — a bright trail sweeping around the ring.
  /// Solid stroke with opacity fade handled by the arc shape itself.
  private var workingOverlay: some View {
    OrbitalArcShape(sweepFraction: 0.2)
      .stroke(
        Color.statusWorking.opacity(0.8),
        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
      )
      .frame(width: size, height: size)
      .rotationEffect(.degrees(orbitRotation))
      .onAppear {
        withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
          orbitRotation = 360
        }
      }
  }

  /// Pulsing radar ping — concentric ring expands outward and fades.
  /// Center dot stays solid for a stable anchor point.
  private var attentionOverlay: some View {
    ZStack {
      // Expanding ping ring
      Circle()
        .strokeBorder(status.color.opacity(0.5 * Double(1 - pulsePhase)), lineWidth: 1)
        .frame(
          width: size * (1 + pulsePhase * 0.6),
          height: size * (1 + pulsePhase * 0.6)
        )
        .onAppear {
          withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
            pulsePhase = 1.0
          }
        }

      // Solid center dot — the signal source
      Circle()
        .fill(status.color)
        .frame(width: size * 0.35, height: size * 0.35)
    }
  }

  /// Calm center dot — docked, waiting for input.
  private var replyOverlay: some View {
    Circle()
      .fill(Color.statusReply.opacity(0.5))
      .frame(width: size * 0.3, height: size * 0.3)
  }

  /// Faint center point — dormant.
  private var endedOverlay: some View {
    Circle()
      .fill(Color.statusEnded.opacity(0.25))
      .frame(width: size * 0.25, height: size * 0.25)
  }

  // MARK: - Style Computation

  private var baseRingOpacity: Double {
    switch status {
    case .working: 0.3
    case .permission, .question: 0.4
    case .reply: 0.25
    case .ended: 0.12
    }
  }

  private var glowIntensity: Double {
    switch status {
    case .working: 0.15
    case .permission, .question: 0.25
    case .reply: 0.08
    case .ended: 0
    }
  }

  private var glowRadius: CGFloat {
    switch status {
    case .working: 6
    case .permission, .question: 8
    case .reply: 4
    case .ended: 0
    }
  }
}

// MARK: - Orbital Arc Shape

/// A partial arc for the orbiting satellite effect.
/// Starts at the top (-90°) and sweeps clockwise by `sweepFraction` of 360°.
struct OrbitalArcShape: Shape {
  let sweepFraction: Double

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2
    path.addArc(
      center: center,
      radius: radius,
      startAngle: .degrees(-90),
      endAngle: .degrees(-90 + sweepFraction * 360),
      clockwise: false
    )
    return path
  }
}

// MARK: - Preview

#Preview("All States") {
  HStack(spacing: 24) {
    VStack(spacing: 8) {
      OrbitalStatusIndicator(status: .working, size: 20)
      Text("Working").font(.caption2)
    }
    VStack(spacing: 8) {
      OrbitalStatusIndicator(status: .permission, size: 20)
      Text("Permission").font(.caption2)
    }
    VStack(spacing: 8) {
      OrbitalStatusIndicator(status: .question, size: 20)
      Text("Question").font(.caption2)
    }
    VStack(spacing: 8) {
      OrbitalStatusIndicator(status: .reply, size: 20)
      Text("Reply").font(.caption2)
    }
    VStack(spacing: 8) {
      OrbitalStatusIndicator(status: .ended, size: 20)
      Text("Ended").font(.caption2)
    }
  }
  .padding(32)
  .background(Color.backgroundPrimary)
  .preferredColorScheme(.dark)
}

#Preview("Sizes") {
  HStack(spacing: 20) {
    OrbitalStatusIndicator(status: .working, size: 10)
    OrbitalStatusIndicator(status: .working, size: 14)
    OrbitalStatusIndicator(status: .working, size: 20)
    OrbitalStatusIndicator(status: .working, size: 28)
  }
  .padding(32)
  .background(Color.backgroundPrimary)
  .preferredColorScheme(.dark)
}
