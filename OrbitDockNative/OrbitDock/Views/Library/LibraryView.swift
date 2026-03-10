//
//  LibraryView.swift
//  OrbitDock
//
//  Project-centric session archive with explicit provider and endpoint filters.
//

import SwiftUI

struct LibraryView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(AppRouter.self) private var router

  let sessions: [Session]
  var containerWidth: CGFloat? = nil

  @State private var searchText = ""
  @State private var sort: ActiveSessionSort = .recent
  @State private var providerFilter: ActiveSessionProviderFilter = .all
  @State private var selectedEndpointId: UUID?
  @State private var collapsedGroups: Set<String> = []

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(
      horizontalSizeClass: horizontalSizeClass,
      containerWidth: containerWidth
    )
  }

  private var archiveState: LibraryArchiveState {
    LibraryArchivePlanner.state(
      sessions: sessions,
      searchText: searchText,
      providerFilter: providerFilter,
      selectedEndpointId: selectedEndpointId,
      sort: sort
    )
  }

  private var providerScopedSessions: [Session] {
    archiveState.providerScopedSessions
  }

  private var endpointFacets: [LibraryEndpointFacet] {
    archiveState.endpointFacets
  }

  private var endpointScopedSessions: [Session] {
    archiveState.endpointScopedSessions
  }

  private var filteredSessions: [Session] {
    archiveState.filteredSessions
  }

  private var summary: LibraryArchiveSummary {
    archiveState.summary
  }

  private var selectedEndpointFacet: LibraryEndpointFacet? {
    archiveState.selectedEndpointFacet
  }

  private var hasActiveFilters: Bool {
    !searchText.isEmpty || providerFilter != .all || selectedEndpointFacet != nil
  }

  private var scopeDescription: String {
    archiveState.scopeDescription
  }

  private var projectGroups: [LibraryProjectGroup] {
    archiveState.projectGroups
  }

  var body: some View {
    VStack(spacing: 0) {
      LibraryHeaderSection(
        layoutMode: layoutMode,
        scopeDescription: scopeDescription,
        hasActiveFilters: hasActiveFilters,
        summary: summary,
        selectedEndpointFacet: selectedEndpointFacet,
        endpointFacets: endpointFacets,
        providerScopedSessionCount: providerScopedSessions.count,
        searchText: $searchText,
        sort: $sort,
        providerFilter: $providerFilter,
        selectedEndpointId: $selectedEndpointId
      )

      if projectGroups.isEmpty {
        LibraryEmptyState(hasActiveFilters: hasActiveFilters)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: Spacing.lg) {
            ForEach(projectGroups) { group in
              projectSection(group)
            }
          }
          .padding(layoutMode.contentPadding)
        }
        .scrollContentBackground(.hidden)
      }
    }
  }

  // MARK: - Project Section

  private func projectSection(_ group: LibraryProjectGroup) -> some View {
    let isCollapsed = collapsedGroups.contains(group.id)

    return VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(Motion.hover) {
          if isCollapsed {
            collapsedGroups.remove(group.id)
          } else {
            collapsedGroups.insert(group.id)
          }
        }
      } label: {
        VStack(alignment: .leading, spacing: Spacing.sm) {
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

              HStack(spacing: Spacing.sm_) {
                if group.liveSessions.count > 0 {
                  LibraryInlineStat(
                    text: "\(group.liveSessions.count) live",
                    tint: .statusWorking
                  )
                }

                if group.cachedActiveSessionCount > 0 {
                  LibraryInlineStat(
                    text: "\(group.cachedActiveSessionCount) cached",
                    tint: .statusPermission
                  )
                }

                if group.totalCost > 0 {
                  LibraryInlineStat(
                    text: LibraryValueFormatter.cost(group.totalCost),
                    tint: .textSecondary
                  )
                }

                if group.totalTokens > 0 {
                  LibraryInlineStat(
                    text: LibraryValueFormatter.tokens(group.totalTokens),
                    tint: .textTertiary
                  )
                }
              }
            }

            Spacer(minLength: Spacing.md)
          }

          if !group.endpointFacets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: Spacing.xs) {
                ForEach(group.endpointFacets.prefix(3)) { facet in
                  LibraryFilterChip(
                    title: facet.name,
                    count: facet.sessionCount,
                    icon: facet.isConnected ? "network" : "wifi.slash",
                    tint: facet.isConnected ? .accent : .statusPermission,
                    isSelected: selectedEndpointId == facet.endpointId
                  )
                }

                if group.endpointFacets.count > 3 {
                  LibraryFilterChip(
                    title: "+\(group.endpointFacets.count - 3)",
                    tint: .textSecondary,
                    isSelected: false
                  )
                }
              }
              .padding(.leading, 20)
            }
          }
        }
        .padding(.horizontal, layoutMode.isPhoneCompact ? Spacing.md : Spacing.lg_)
        .padding(.vertical, Spacing.md)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if !isCollapsed {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if !group.liveSessions.isEmpty {
            projectSubsection(
              title: "Live Now",
              count: group.liveSessions.count,
              tint: .statusWorking,
              sessions: group.liveSessions
            )
          }

          if !group.archivedSessions.isEmpty {
            if !group.liveSessions.isEmpty {
              Divider()
                .overlay(Color.surfaceBorder.opacity(OpacityTier.subtle))
                .padding(.leading, layoutMode.isPhoneCompact ? Spacing.md : Spacing.lg)
            }

            projectSubsection(
              title: group.cachedActiveSessionCount > 0 ? "Cached / Archive" : "Archive",
              count: group.archivedSessions.count,
              tint: group.cachedActiveSessionCount > 0 ? .statusPermission : .textTertiary,
              sessions: group.archivedSessions
            )
          }
        }
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

  private func projectSubsection(
    title: String,
    count: Int,
    tint: Color,
    sessions: [Session]
  ) -> some View {
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
            onSelect: { selectSession(session) },
            isAttentionPromoted: SessionDisplayStatus.from(session).needsAttention
          )
        }
      }
      .padding(.horizontal, layoutMode.isPhoneCompact ? Spacing.sm : Spacing.md)
    }
  }

  // MARK: - Navigation

  private func selectSession(_ session: Session) {
    withAnimation(Motion.standard) {
      router.navigateToSession(scopedID: session.scopedID)
    }
  }
}
