import SwiftUI

struct LibraryProjectSection: View {
  let group: LibraryProjectGroup
  let layoutMode: DashboardLayoutMode
  let isCollapsed: Bool
  let selectedEndpointId: UUID?
  let onToggleCollapsed: () -> Void
  let onSelectSession: (SessionSummary) -> Void

  private var sectionState: LibraryProjectSectionState {
    LibraryProjectSectionState.build(group: group)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggleCollapsed) {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          LibraryProjectSectionHeader(
            group: group,
            sectionState: sectionState,
            isCollapsed: isCollapsed
          )

          if !group.endpointFacets.isEmpty {
            LibraryProjectEndpointFacetRow(
              facets: group.endpointFacets,
              selectedEndpointId: selectedEndpointId,
              hiddenFacetCount: sectionState.hiddenEndpointFacetCount
            )
          }
        }
        .padding(.horizontal, layoutMode.isPhoneCompact ? Spacing.md : Spacing.lg_)
        .padding(.vertical, Spacing.md)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if !isCollapsed {
        LibraryProjectSectionContent(
          group: group,
          sectionState: sectionState,
          layoutMode: layoutMode,
          onSelectSession: onSelectSession
        )
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

private struct LibraryProjectEndpointFacetRow: View {
  let facets: [LibraryEndpointFacet]
  let selectedEndpointId: UUID?
  let hiddenFacetCount: Int

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        ForEach(facets.prefix(3)) { facet in
          LibraryFilterChip(
            title: facet.name,
            count: facet.sessionCount,
            icon: facet.isConnected ? "network" : "wifi.slash",
            tint: facet.isConnected ? .accent : .statusPermission,
            isSelected: selectedEndpointId == facet.endpointId
          )
        }

        if hiddenFacetCount > 0 {
          LibraryFilterChip(
            title: "+\(hiddenFacetCount)",
            tint: .textSecondary,
            isSelected: false
          )
        }
      }
      .padding(.leading, 20)
    }
  }
}

private struct LibraryProjectSectionContent: View {
  let group: LibraryProjectGroup
  let sectionState: LibraryProjectSectionState
  let layoutMode: DashboardLayoutMode
  let onSelectSession: (SessionSummary) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if !group.liveSessions.isEmpty {
        LibraryProjectSubsection(
          title: "Live Now",
          count: group.liveSessions.count,
          tint: .statusWorking,
          sessions: group.liveSessions,
          layoutMode: layoutMode,
          onSelectSession: onSelectSession
        )
      }

      if !group.archivedSessions.isEmpty {
        if !group.liveSessions.isEmpty {
          Divider()
            .overlay(Color.surfaceBorder.opacity(OpacityTier.subtle))
            .padding(.leading, layoutMode.isPhoneCompact ? Spacing.md : Spacing.lg)
        }

        LibraryProjectSubsection(
          title: sectionState.archiveSectionTitle,
          count: group.archivedSessions.count,
          tint: sectionState.archiveSectionKind == .cachedArchive ? .statusPermission : .textTertiary,
          sessions: group.archivedSessions,
          layoutMode: layoutMode,
          onSelectSession: onSelectSession
        )
      }
    }
  }
}

struct LibraryProjectSubsection: View {
  let title: String
  let count: Int
  let tint: Color
  let sessions: [SessionSummary]
  let layoutMode: DashboardLayoutMode
  let onSelectSession: (SessionSummary) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(spacing: Spacing.xs) {
        Text(title.uppercased())
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(tint)

        Text("\(count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(tint)
      }
      .padding(.leading, layoutMode.isPhoneCompact ? Spacing.md : Spacing.lg)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        ForEach(sessions, id: \.scopedID) { session in
          FlatSessionRow(
            session: session,
            onSelect: { onSelectSession(session) },
            isAttentionPromoted: SessionDisplayStatus.from(session).needsAttention
          )
        }
      }
      .padding(.horizontal, layoutMode.isPhoneCompact ? Spacing.sm : Spacing.md)
    }
  }
}
