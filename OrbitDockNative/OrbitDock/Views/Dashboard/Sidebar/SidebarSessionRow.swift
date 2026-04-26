import SwiftUI

struct SidebarSessionRow: View {
  let session: DashboardConversationRecord
  let isSelected: Bool

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(DashboardDataService.self) private var dashboardDataService
  @Environment(PinnedSessionsService.self) private var pinnedService
  @Environment(\.rootSessionActions) private var rootSessionActions
  @State private var isHovered = false
  @State private var isEnding = false

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var displayStatus: SessionDisplayStatus {
    session.displayStatus
  }

  private var recencyLabel: String? {
    guard let date = session.lastActivityAt ?? session.startedAt else { return nil }
    return RelativeClock.shortLabel(for: date)
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      OrbitalStatusIndicator(status: displayStatus, size: 12)

      VStack(alignment: .leading, spacing: 2) {
        titleLine
        stateContent
      }
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
    .contextMenu {
      DashboardSessionContextActions.pinActions(for: session, pinnedService: pinnedService)

      Divider()

      DashboardSessionContextActions.conversationBaseActions(for: session)

      if session.canEnd {
        Divider()
        Button(role: .destructive) {
          Task { await endSession() }
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    }
    .platformTrailingSwipeActions(allowsFullSwipe: false) {
      if session.canEnd {
        Button(role: .destructive) {
          Task { await endSession() }
        } label: {
          Label(isEnding ? "Ending" : "End", systemImage: isEnding ? "stop.circle.fill" : "stop.circle")
        }
      }
    }
    .platformHover($isHovered)
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

  // MARK: - State-Driven Metadata

  @ViewBuilder
  private var stateContent: some View {
    switch displayStatus {
      case .working:
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spacing.xs) {
            providerAndModel
            if let branch = session.compactBranchLabel {
              metaDot
              branchText(branch)
            }
            metaDot
            workingLabel
          }
          HStack(spacing: Spacing.xs) {
            providerAndModel
            metaDot
            workingLabel
          }
          providerAndModel
        }

      case .permission:
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spacing.xs) {
            providerAndModel
            metaDot
            alertText(color: .statusPermission, fallback: "awaiting approval")
          }
          providerAndModel
        }

      case .question:
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spacing.xs) {
            providerAndModel
            metaDot
            alertText(color: .statusQuestion, fallback: "has a question")
          }
          providerAndModel
        }

      case .reply:
        if let diff = visibleDiffPreview {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
              providerAndModel
              metaDot
              diffStats(diff)
              if let branch = session.compactBranchLabel {
                metaDot
                branchText(branch)
              }
            }
            HStack(spacing: Spacing.xs) {
              providerAndModel
              metaDot
              diffStats(diff)
            }
            HStack(spacing: Spacing.xs) {
              providerAndModel
              if let branch = session.compactBranchLabel {
                metaDot
                branchText(branch)
              }
            }
          }
        } else {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
              providerAndModel
              if let branch = session.compactBranchLabel {
                metaDot
                branchText(branch)
              }
              metaDot
              replyContent
            }
            HStack(spacing: Spacing.xs) {
              providerAndModel
              metaDot
              replyContent
            }
            HStack(spacing: Spacing.xs) {
              providerAndModel
              if let branch = session.compactBranchLabel {
                metaDot
                branchText(branch)
              }
            }
          }
        }

      case .ended:
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spacing.xs) {
            providerAndModel
            if let diff = visibleDiffPreview {
              metaDot
              diffStats(diff)
            }
            if let branch = session.compactBranchLabel {
              metaDot
              branchText(branch)
            }
          }
          HStack(spacing: Spacing.xs) {
            providerAndModel
            if let diff = visibleDiffPreview {
              metaDot
              diffStats(diff)
            }
          }
          HStack(spacing: Spacing.xs) {
            providerAndModel
            if let branch = session.compactBranchLabel {
              metaDot
              branchText(branch)
            }
          }
          providerAndModel
        }
    }
  }

  private var visibleDiffPreview: ServerDashboardDiffPreview? {
    guard let diff = session.diffPreview else { return nil }
    let hasVisibleStats = diff.fileCount > 0 || diff.additions > 0 || diff.deletions > 0
    return hasVisibleStats ? diff : nil
  }

  @ViewBuilder
  private var replyContent: some View {
    Text(session.compactPreviewText)
      .font(.system(size: TypeScale.mini, weight: .regular))
      .foregroundStyle(Color.textQuaternary)
      .lineLimit(1)
  }

  // MARK: - Metadata Components

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

  private var metaDot: some View {
    Circle()
      .fill(Color.textQuaternary.opacity(0.6))
      .frame(width: 2, height: 2)
  }

  private func branchText(_ branch: String) -> some View {
    Text(branch)
      .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.gitBranch.opacity(0.5))
      .lineLimit(1)
  }

  @ViewBuilder
  private var workingLabel: some View {
    if let tool = session.pendingToolName {
      Text(tool)
        .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.statusWorking.opacity(0.8))
        .lineLimit(1)
    } else {
      Text("thinking\u{2026}")
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.statusWorking.opacity(0.7))
    }
  }

  private func alertText(color: Color, fallback: String) -> some View {
    Text(!session.alertContextText.isEmpty ? session.alertContextText : fallback)
      .font(.system(size: TypeScale.mini, weight: .medium))
      .foregroundStyle(color.opacity(0.8))
      .lineLimit(1)
  }

  private func diffStats(_ diff: ServerDashboardDiffPreview) -> some View {
    let net = Int(diff.additions) - Int(diff.deletions)
    let deltaColor: Color = net > 0 ? .feedbackPositive.opacity(0.6) : net < 0 ? .feedbackCaution.opacity(0.5) : .textQuaternary
    let deltaText = net >= 0 ? "+\(formatLineCount(net))" : formatLineCount(net)

    return HStack(spacing: Spacing.xs) {
      Text(deltaText)
        .foregroundStyle(deltaColor)
      Text("Δ")
        .foregroundStyle(Color.textQuaternary.opacity(0.6))
      if diff.fileCount > 0 {
        Text("·")
          .foregroundStyle(Color.textQuaternary.opacity(0.5))
        Text("\(diff.fileCount)f")
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
  }

  private func formatLineCount(_ count: Int) -> String {
    let absCount = abs(count)
    if absCount >= 1000 {
      let k = Double(absCount) / 1000.0
      return String(format: "%.1fk", k).replacingOccurrences(of: ".0k", with: "k")
    }
    return "\(count)"
  }

  // MARK: - Actions

  private func endSession() async {
    isEnding = true
    defer { isEnding = false }
    try? await rootSessionActions.endSession(session.sessionRef)
    await dashboardDataService.refreshNow()
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

private enum RelativeClock {
  static func shortLabel(for date: Date, now: Date = .now) -> String {
    let interval = max(0, now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }
}
