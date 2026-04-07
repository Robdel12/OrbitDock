import SwiftUI

/// Attention-demanding card for sessions needing user response.
///
/// "Incoming transmission" design: the `OrbitalStatusIndicator`'s pulse animation
/// draws the eye, while a subtle glow pulse on the card shadow reinforces urgency.
/// The card itself stays visually stable — no rotating borders or heavy effects.
///
/// Glow pulse is composited by Core Animation (opacity-only animation on shadow
/// layer = near-zero CPU cost).
struct TransmissionCard: View {
  let session: DashboardConversationRecord
  let onTap: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var glowPhase: CGFloat = 0

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var statusColor: Color { session.displayStatus.color }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: Spacing.md) {
        OrbitalStatusIndicator(status: session.displayStatus, size: 20)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          titleRow
          contextLine
          metadataRow
        }
      }
      .padding(layoutMode.isPhoneCompact ? Spacing.lg : Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: 44)
      .background(cardBackground)
      .overlay(cardBorder)
      .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
      .shadow(
        color: statusColor.opacity(reduceMotion ? 0.15 : glowOpacity),
        radius: 16,
        y: 0
      )
      .shadow(color: statusColor.opacity(0.08), radius: 4, y: 0)
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
          glowPhase = 1
        }
      }
    }
    .buttonStyle(.plain)
  }

  // MARK: - Content Rows

  private var titleRow: some View {
    HStack(spacing: Spacing.sm) {
      Text(session.title)
        .font(.system(size: TypeScale.subhead, weight: .bold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)

      Spacer(minLength: 0)

      Text(session.displayStatus.label.uppercased())
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(statusColor)
        .tracking(0.5)
        .padding(.horizontal, Spacing.sm_)
        .padding(.vertical, 2)
        .background(statusColor.opacity(OpacityTier.light), in: Capsule(style: .continuous))
    }
  }

  @ViewBuilder
  private var contextLine: some View {
    if !session.alertContextText.isEmpty {
      Text(session.alertContextText)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(2)
    }
  }

  private var metadataRow: some View {
    HStack(spacing: Spacing.sm_) {
      HStack(spacing: Spacing.gap) {
        Image(systemName: session.provider.icon)
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(session.provider.accentColor.opacity(0.7))

        if let model = session.modelDisplayLabel {
          Text(model)
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      if let tool = session.pendingToolName {
        Text("·")
          .foregroundStyle(Color.textQuaternary)
        Text(tool)
          .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
          .foregroundStyle(statusColor.opacity(0.7))
          .lineLimit(1)
      }

      Spacer()

      if let branch = session.compactBranchLabel {
        Text(branch)
          .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.gitBranch.opacity(0.5))
          .lineLimit(1)
      }

      if let recency = recencyLabel {
        Text(recency)
          .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }
    }
  }

  // MARK: - Visual Layers

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
      .fill(statusColor.opacity(OpacityTier.tint))
  }

  private var cardBorder: some View {
    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
      .strokeBorder(statusColor.opacity(OpacityTier.medium), lineWidth: 1.5)
  }

  private var glowOpacity: Double {
    0.12 + 0.10 * Double(glowPhase)
  }

  private var recencyLabel: String? {
    guard let date = session.lastActivityAt ?? session.startedAt else { return nil }
    let interval = max(0, Date.now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }
}
