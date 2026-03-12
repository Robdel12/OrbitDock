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

  let sessions: [SessionSummary]
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

  private var providerScopedSessions: [SessionSummary] {
    archiveState.providerScopedSessions
  }

  private var endpointFacets: [LibraryEndpointFacet] {
    archiveState.endpointFacets
  }

  private var endpointScopedSessions: [SessionSummary] {
    archiveState.endpointScopedSessions
  }

  private var filteredSessions: [SessionSummary] {
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
              LibraryProjectSection(
                group: group,
                layoutMode: layoutMode,
                isCollapsed: collapsedGroups.contains(group.id),
                selectedEndpointId: selectedEndpointId,
                onToggleCollapsed: {
                  withAnimation(Motion.hover) {
                    if collapsedGroups.contains(group.id) {
                      collapsedGroups.remove(group.id)
                    } else {
                      collapsedGroups.insert(group.id)
                    }
                  }
                },
                onSelectSession: selectSession
              )
            }
          }
          .padding(layoutMode.contentPadding)
        }
        .scrollContentBackground(.hidden)
      }
    }
  }

  // MARK: - Navigation

  private func selectSession(_ session: SessionSummary) {
    withAnimation(Motion.standard) {
      router.navigateToSession(scopedID: session.scopedID)
    }
  }
}
