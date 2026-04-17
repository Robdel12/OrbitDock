import SwiftUI

struct OverviewAttentionZone: View {
  let sessions: [DashboardConversationRecord]
  let layoutMode: DashboardLayoutMode
  let onSelect: (DashboardConversationRecord) -> Void
  let onEnd: (DashboardConversationRecord) async -> Void

  private var columns: [GridItem] {
    layoutMode.isPhoneCompact
      ? [GridItem(.flexible())]
      : [GridItem(.flexible(), spacing: Spacing.md), GridItem(.flexible(), spacing: Spacing.md)]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      SectorHeader(title: "Incoming", color: .statusPermission, count: sessions.count)

      LazyVGrid(columns: columns, spacing: Spacing.md) {
        ForEach(sessions) { session in
          TransmissionCard(session: session) {
            onSelect(session)
          }
          .modifier(OverviewSessionContextMenu(session: session, onEnd: onEnd))
        }
      }
    }
  }
}

struct OverviewProjectGroupSection: View {
  let group: ConversationProjectGroup
  let sessions: [DashboardConversationRecord]
  @Binding var isCollapsed: Bool
  let layoutMode: DashboardLayoutMode
  let onSelect: (DashboardConversationRecord) -> Void
  let onEnd: (DashboardConversationRecord) async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SectorHeader(
        title: group.name,
        color: group.signalColor,
        count: sessions.count,
        isCollapsed: isCollapsed,
        onToggle: toggleCollapsed
      )

      if isCollapsed {
        signalStrip
      } else {
        expandedRows
      }
    }
  }

  private var signalStrip: some View {
    HStack(spacing: 2) {
      ForEach(sessions) { session in
        Circle()
          .fill(session.displayStatus.color)
          .frame(width: 4, height: 4)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.bottom, Spacing.xs)
  }

  private var expandedRows: some View {
    VStack(spacing: 0) {
      ForEach(sessions) { session in
        OverviewSessionRow(
          session: session,
          layoutMode: layoutMode,
          onSelect: onSelect,
          onEnd: onEnd
        )

        if session.id != sessions.last?.id {
          Rectangle()
            .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
            .frame(height: 1)
            .padding(.leading, Spacing.lg)
        }
      }
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
  }

  private func toggleCollapsed() {
    withAnimation(Motion.hover) {
      isCollapsed.toggle()
    }
  }
}

private struct OverviewSessionRow: View {
  let session: DashboardConversationRecord
  let layoutMode: DashboardLayoutMode
  let onSelect: (DashboardConversationRecord) -> Void
  let onEnd: (DashboardConversationRecord) async -> Void

  private var isActive: Bool {
    session.displayStatus == .working || session.displayStatus.needsAttention
  }

  var body: some View {
    Button {
      onSelect(session)
    } label: {
      HStack(spacing: Spacing.sm) {
        OrbitalStatusIndicator(status: session.displayStatus, size: 12)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: Spacing.xs) {
            Text(session.title)
              .font(.system(size: TypeScale.caption, weight: isActive ? .bold : .semibold))
              .foregroundStyle(isActive ? Color.textPrimary : Color.textSecondary)
              .lineLimit(1)

            Spacer(minLength: Spacing.xs)

            if let recency = DashboardFormatters.recency(for: session.lastActivityAt ?? session.startedAt) {
              Text(recency)
                .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
            }
          }

          OverviewSessionMetadata(session: session)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, layoutMode.isPhoneCompact ? Spacing.md_ : Spacing.sm)
      .frame(minHeight: layoutMode.isPhoneCompact ? 44 : 0)
      .opacity(session.displayStatus == .ended ? 0.55 : 1.0)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .modifier(OverviewSessionContextMenu(session: session, onEnd: onEnd))
  }
}

private struct OverviewSessionMetadata: View {
  let session: DashboardConversationRecord

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Spacing.xs) {
        OverviewProviderLabel(session: session)
        OverviewActivityLabel(session: session)
        if let branch = session.compactBranchLabel {
          OverviewBranchLabel(branch: branch)
        }
      }

      HStack(spacing: Spacing.xs) {
        OverviewProviderLabel(session: session)
        OverviewActivityLabel(session: session)
      }

      HStack(spacing: Spacing.xs) {
        OverviewProviderLabel(session: session)
      }
    }
  }
}

private struct OverviewProviderLabel: View {
  let session: DashboardConversationRecord

  var body: some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: session.provider.icon)
        .font(.system(size: 7, weight: .semibold))
        .foregroundStyle(session.provider.accentColor.opacity(0.7))

      if let model = session.modelDisplayLabel {
        Text(model)
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }
    }
  }
}

private struct OverviewActivityLabel: View {
  let session: DashboardConversationRecord

  @ViewBuilder
  var body: some View {
    switch session.displayStatus {
      case .working:
        if let toolName = session.pendingToolName {
          Text(toolName)
            .font(.system(size: TypeScale.mini, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.statusWorking.opacity(0.8))
            .lineLimit(1)
        } else {
          Text("thinking…")
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(Color.statusWorking.opacity(0.7))
        }

      case .permission:
        Text(!session.alertContextText.isEmpty ? session.alertContextText : "awaiting approval")
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.statusPermission.opacity(0.8))
          .lineLimit(1)

      case .question:
        Text(!session.alertContextText.isEmpty ? session.alertContextText : "has a question")
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.statusQuestion.opacity(0.8))
          .lineLimit(1)

      case .reply:
        if let diff = session.diffPreview, diff.fileCount > 0 {
          OverviewDiffStats(diff: diff)
        } else {
          Text(session.compactPreviewText)
            .font(.system(size: TypeScale.mini, weight: .regular))
            .foregroundStyle(Color.textQuaternary)
            .lineLimit(1)
        }

      case .ended:
        Text(session.compactPreviewText)
          .font(.system(size: TypeScale.mini, weight: .regular))
          .foregroundStyle(Color.textQuaternary)
          .lineLimit(1)
    }
  }
}

private struct OverviewDiffStats: View {
  let diff: ServerDashboardDiffPreview

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Text("+\(diff.additions)")
        .foregroundStyle(Color.diffAddedAccent)
      Text("-\(diff.deletions)")
        .foregroundStyle(Color.diffRemovedAccent)
      Text("\(diff.fileCount) \(diff.fileCount == 1 ? "file" : "files")")
        .foregroundStyle(Color.textQuaternary)
    }
    .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
  }
}

private struct OverviewBranchLabel: View {
  let branch: String

  var body: some View {
    Text(branch)
      .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.gitBranch.opacity(0.5))
      .lineLimit(1)
  }
}

private struct OverviewSessionContextMenu: ViewModifier {
  let session: DashboardConversationRecord
  let onEnd: (DashboardConversationRecord) async -> Void

  func body(content: Content) -> some View {
    content.contextMenu {
      DashboardSessionContextActions.conversationBaseActions(for: session)

      if session.canEnd {
        Divider()
        Button(role: .destructive) {
          Task { await onEnd(session) }
        } label: {
          Label("End Session", systemImage: "stop.circle")
        }
      }
    }
  }
}
