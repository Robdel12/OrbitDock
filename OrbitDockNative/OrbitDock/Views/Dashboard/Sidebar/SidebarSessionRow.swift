import SwiftUI

struct SidebarSessionRow: View {
  let session: DashboardConversationRecord
  let isSelected: Bool

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var isHovered = false

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var displayStatus: SessionDisplayStatus {
    session.displayStatus
  }

  private var recencyLabel: String? {
    guard let date = session.lastActivityAt ?? session.startedAt else { return nil }
    let interval = max(0, Date.now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      titleLine
      stateContent
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, layoutMode.isPhoneCompact ? Spacing.md_ : Spacing.sm_)
    .frame(minHeight: layoutMode.isPhoneCompact ? 44 : 0)
    .opacity(displayStatus == .ended ? 0.55 : 1.0)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(rowFill)
        .padding(.horizontal, Spacing.xxs)
    )
    .contentShape(Rectangle())
    #if os(macOS)
      .onHover { isHovered = $0 }
    #endif
  }

  // MARK: - Title Line

  private var titleLine: some View {
    HStack(spacing: Spacing.xs) {
      Text(session.title)
        .font(.system(size: TypeScale.caption, weight: titleWeight))
        .foregroundStyle(titleColor)
        .lineLimit(1)

      Spacer(minLength: 2)

      if let label = recencyLabel {
        Text(label)
          .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
          .monospacedDigit()
      }
    }
  }

  // MARK: - State-Driven Content

  @ViewBuilder
  private var stateContent: some View {
    switch displayStatus {
    case .working:
      HStack(spacing: Spacing.xs) {
        Image(systemName: "bolt.fill")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.statusWorking)

        if let toolName = session.pendingToolName {
          Text(toolName)
            .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.statusWorking.opacity(0.8))
            .lineLimit(1)
        } else {
          Text("thinking\u{2026}")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.statusWorking.opacity(0.7))
        }
      }

    case .permission:
      HStack(spacing: Spacing.xs) {
        Image(systemName: "lock.fill")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.statusPermission)

        if let toolName = session.pendingToolName {
          Text(toolName)
            .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.statusPermission.opacity(0.8))
            .lineLimit(1)
        } else {
          Text("awaiting approval")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.statusPermission.opacity(0.7))
        }
      }

    case .question:
      HStack(spacing: Spacing.xs) {
        Image(systemName: "questionmark.bubble.fill")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.statusQuestion)

        Text(!session.alertContextText.isEmpty ? session.alertContextText : "has a question")
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.statusQuestion.opacity(0.8))
          .lineLimit(1)
      }

    case .reply, .ended:
      metadataLine
    }
  }

  /// Standard provider + model + branch metadata (for reply/ended states)
  private var metadataLine: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Spacing.xs) {
        providerAndModel
        if let branch = session.compactBranchLabel {
          Circle()
            .fill(Color.textQuaternary.opacity(0.6))
            .frame(width: 2, height: 2)
          Text(branch)
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.gitBranch.opacity(0.5))
            .lineLimit(1)
        }
      }
      HStack(spacing: Spacing.xs) {
        providerAndModel
      }
    }
  }

  private var providerAndModel: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: session.provider.icon)
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(session.provider.accentColor.opacity(0.7))

      if let model = session.modelDisplayLabel {
        Text(model)
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
      }
    }
  }

  // MARK: - Style Computation

  private var titleWeight: Font.Weight {
    if isSelected { return .bold }
    switch displayStatus {
    case .working, .permission, .question: return .semibold
    case .reply: return .medium
    case .ended: return .regular
    }
  }

  private var titleColor: Color {
    if isSelected { return .textPrimary }
    switch displayStatus {
    case .working, .permission, .question: return .textPrimary
    case .reply: return .textSecondary
    case .ended: return .textTertiary
    }
  }

  private var rowFill: Color {
    if isSelected { return Color.surfaceSelected }
    if isHovered { return Color.surfaceHover }
    switch displayStatus {
    case .permission, .question:
      return displayStatus.color.opacity(OpacityTier.tint)
    case .working:
      return Color.statusWorking.opacity(OpacityTier.tint)
    default:
      return .clear
    }
  }
}
