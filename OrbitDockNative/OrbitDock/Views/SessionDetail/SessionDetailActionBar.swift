import SwiftUI

struct SessionDetailRegularActionBar: View {
  let state: SessionDetailActionBarState
  let usageStats: TranscriptUsageStats
  let jumpToLatest: () -> Void
  let togglePinned: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      if let branchLabel = state.branchLabel {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: TypeScale.micro, weight: .semibold))
          Text(branchLabel)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(Color.gitBranch)
        .padding(.horizontal, Spacing.md)

        SessionDetailStripDivider()
      }

      Text(state.projectPathLabel)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, Spacing.md)

      Spacer()

      if let formattedCost = state.formattedCost {
        Text(formattedCost)
          .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, Spacing.md)

        SessionDetailStripDivider()
      }

      ContextGaugeCompact(stats: usageStats)
        .padding(.horizontal, Spacing.md)

      SessionDetailStripDivider()

      if state.showsUnreadIndicator {
        Button(action: jumpToLatest) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.down")
              .font(.system(size: TypeScale.micro, weight: .bold))
            Text("\(state.unreadCount) new")
              .font(.system(size: TypeScale.caption, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(Color.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.sm)
        .transition(.scale.combined(with: .opacity))
      }

      Button(action: togglePinned) {
        Text(state.followLabel)
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(state.isPinned ? Color.textTertiary : Color.textPrimary)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, Spacing.md)
    }
    .frame(height: 30)
    .background(Color.backgroundSecondary)
    .animation(Motion.standard, value: state.isPinned)
    .animation(Motion.standard, value: state.unreadCount)
  }
}

struct SessionDetailCompactActionBar: View {
  let state: SessionDetailActionBarState
  let usageStats: TranscriptUsageStats
  let canRevealInFileBrowser: Bool
  let copiedResume: Bool
  let onCopyResume: () -> Void
  let onRevealInFinder: () -> Void
  let jumpToLatest: () -> Void
  let togglePinned: () -> Void

  var body: some View {
    VStack(spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        Button(action: onCopyResume) {
          Image(systemName: copiedResume ? "checkmark" : "doc.on.doc")
            .font(.system(size: TypeScale.code, weight: .medium))
            .frame(width: 30, height: 30)
            .foregroundStyle(copiedResume ? Color.feedbackPositive : .secondary)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Copy resume command")

        if canRevealInFileBrowser {
          Button(action: onRevealInFinder) {
            Image(systemName: "folder")
              .font(.system(size: TypeScale.code, weight: .medium))
              .frame(width: 30, height: 30)
              .foregroundStyle(.secondary)
              .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
          }
          .buttonStyle(.plain)
          .help("Open in Finder")
        }

        Spacer(minLength: 0)

        if state.showsUnreadIndicator {
          Button(action: jumpToLatest) {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "arrow.down")
                .font(.system(size: TypeScale.caption, weight: .bold))
              Text(state.unreadBadgeText)
                .font(.system(size: TypeScale.code, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.accent, in: Capsule())
          }
          .buttonStyle(.plain)
          .transition(.scale.combined(with: .opacity))
        }

        Button(action: togglePinned) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: state.compactFollowIcon)
              .font(.system(size: TypeScale.body, weight: .medium))
            Text(state.followLabel)
              .font(.system(size: TypeScale.code, weight: .medium))
          }
          .foregroundStyle(state.isPinned ? .secondary : .primary)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .fill(state.isPinned ? Color.clear : Color.backgroundTertiary)
          )
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, Spacing.md)

      ScrollView(.horizontal) {
        HStack(spacing: Spacing.sm) {
          ContextGaugeCompact(stats: usageStats)

          if let formattedCost = state.formattedCost {
            Text(formattedCost)
              .font(.system(size: TypeScale.code, weight: .semibold, design: .monospaced))
              .foregroundStyle(.primary.opacity(OpacityTier.vivid))
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xs)
              .background(Color.backgroundTertiary, in: Capsule())
          }

          if let branchLabel = state.branchLabel {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: TypeScale.caption, weight: .semibold))
              Text(branchLabel)
                .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(Color.gitBranch)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.backgroundTertiary, in: Capsule())
          }

          if let lastActivityAt = state.lastActivityAt {
            Text(lastActivityAt, style: .relative)
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xs)
              .background(Color.backgroundTertiary, in: Capsule())
          }
        }
        .padding(.horizontal, Spacing.md)
      }
      .scrollIndicators(.hidden)
    }
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundSecondary)
    .animation(Motion.standard, value: state.isPinned)
    .animation(Motion.standard, value: state.unreadCount)
  }
}

private struct SessionDetailStripDivider: View {
  var body: some View {
    Color.panelBorder.opacity(0.38)
      .frame(width: 1, height: 14)
  }
}
