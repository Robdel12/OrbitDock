import SwiftUI

struct LibraryProjectSection: View {
  let group: LibraryProjectGroup
  let layoutMode: DashboardLayoutMode
  let isCollapsed: Bool
  let onToggleCollapsed: () -> Void
  let onSelectSession: (RootSessionNode) -> Void

  private var sectionState: LibraryProjectSectionState {
    LibraryProjectSectionState.build(group: group)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggleCollapsed) {
        LibraryProjectSectionHeader(
          group: group,
          sectionState: sectionState,
          isCollapsed: isCollapsed
        )
        .padding(.horizontal, Spacing.lg_)
        .padding(.vertical, Spacing.md)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if !isCollapsed {
        let allSessions = group.liveSessions + group.archivedSessions
        LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
          ForEach(allSessions, id: \.scopedID) { session in
            FlatSessionRow(
              session: session,
              onSelect: { onSelectSession(session) },
              isAttentionPromoted: session.needsAttention
            )
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.md)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.35))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
        )
    )
  }
}

private struct LibraryProjectSectionHeader: View {
  let group: LibraryProjectGroup
  let sectionState: LibraryProjectSectionState
  let isCollapsed: Bool

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
        .font(.system(size: TypeScale.mini, weight: .bold))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 12, height: 18)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.xs) {
          Text(group.name)
            .font(.system(size: TypeScale.body, weight: .bold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)

          LibraryCountPill(text: "\(group.totalSessionCount)", tint: .textTertiary)
        }

        LibraryProjectBadgeRow(badges: sectionState.badges)
      }

      Spacer(minLength: Spacing.md)
    }
  }
}

private struct LibraryProjectBadgeRow: View {
  let badges: [LibraryProjectSectionBadge]

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
        switch badge {
          case let .live(count):
            LibraryInlineStat(text: "\(count) live", tint: .statusWorking)
          case let .cached(count):
            LibraryInlineStat(text: "\(count) cached", tint: .statusPermission)
          case let .cost(value):
            LibraryInlineStat(text: value, tint: .textSecondary)
          case let .tokens(value):
            LibraryInlineStat(text: value, tint: .textTertiary)
        }
      }
    }
  }
}
