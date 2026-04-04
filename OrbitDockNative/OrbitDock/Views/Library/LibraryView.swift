//
//  LibraryView.swift
//  OrbitDock
//
//  Session archive with compact toolbar and flat list on mobile.
//

import SwiftUI

struct LibraryView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(AppRouter.self) private var router

  let sessions: [RootSessionNode]
  let hasMoreSessions: Bool
  let onLoadMoreSessions: () async -> Void
  var containerWidth: CGFloat?

  @State private var searchText = ""
  @State private var sort: ActiveSessionSort = .recent
  @State private var providerFilter: ActiveSessionProviderFilter = .all
  @State private var selectedEndpointId: UUID?
  @State private var collapsedGroups: Set<String> = []
  @State private var showFilterSheet = false
  @State private var isLoadingMore = false

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(
      horizontalSizeClass: horizontalSizeClass,
      containerWidth: containerWidth
    )
  }

  private var hasActiveFilters: Bool {
    !searchText.isEmpty || providerFilter != .all || selectedEndpointId != nil
  }

  var body: some View {
    let archiveState = LibraryArchivePlanner.state(
      sessions: sessions,
      searchText: searchText,
      providerFilter: providerFilter,
      selectedEndpointId: selectedEndpointId,
      sort: sort
    )
    let projectGroups = archiveState.projectGroups

    VStack(spacing: 0) {
      LibraryToolbar(
        layoutMode: layoutMode,
        hasActiveFilters: hasActiveFilters,
        summary: archiveState.summary,
        endpointFacets: archiveState.endpointFacets,
        providerScopedSessionCount: archiveState.providerScopedSessions.count,
        searchText: $searchText,
        sort: $sort,
        providerFilter: $providerFilter,
        selectedEndpointId: $selectedEndpointId,
        showFilterSheet: $showFilterSheet
      )

      if projectGroups.isEmpty {
        LibraryEmptyState(hasActiveFilters: hasActiveFilters)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: layoutMode.isPhoneCompact ? Spacing.xs : Spacing.lg) {
            resultSummaryLine(
              summary: archiveState.summary,
              loadedSessionCount: archiveState.summary.sessionCount
            )

            if layoutMode.isPhoneCompact {
              LibraryFlatList(
                projectGroups: projectGroups,
                onSelectSession: selectSession
              )
            } else {
              ForEach(projectGroups) { group in
                LibraryProjectSection(
                  group: group,
                  layoutMode: layoutMode,
                  isCollapsed: collapsedGroups.contains(group.id),
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

            if hasMoreSessions {
              paginationFooter(loadedSessionCount: archiveState.summary.sessionCount)
              .onAppear {
                Task {
                  await loadMoreSessionsIfNeeded()
                }
              }
            }
          }
          .padding(layoutMode.contentPadding)
        }
        .scrollContentBackground(.hidden)
      }
    }
    .sheet(isPresented: $showFilterSheet) {
      LibraryFilterSheet(
        providerFilter: $providerFilter,
        selectedEndpointId: $selectedEndpointId,
        endpointFacets: archiveState.endpointFacets,
        providerScopedSessionCount: archiveState.providerScopedSessions.count,
        onReset: resetFilters
      )
      .presentationDetents([.height(320), .medium])
      .presentationDragIndicator(.visible)
    }
  }

  // MARK: - Result Summary

  private func resultSummaryLine(
    summary: LibraryArchiveSummary,
    loadedSessionCount: Int
  ) -> some View {
    HStack(spacing: Spacing.xs) {
      Text("\(loadedSessionCount) sessions loaded")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      if !layoutMode.isPhoneCompact, summary.projectCount > 1 {
        Text("across \(summary.projectCount) projects")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textQuaternary)
      }

      if hasActiveFilters {
        Text("filtered")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.accent)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.accent.opacity(OpacityTier.light), in: Capsule())
      }

      if hasMoreSessions {
        Text("more available")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.statusPermission)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.statusPermission.opacity(OpacityTier.light), in: Capsule())
      }
    }
    .padding(.horizontal, layoutMode.isPhoneCompact ? Spacing.sm : Spacing.md)
  }

  private func paginationFooter(loadedSessionCount: Int) -> some View {
    HStack(spacing: Spacing.xs) {
      if isLoadingMore {
        ProgressView()
          .scaleEffect(0.8)
      } else {
        Image(systemName: "arrow.down.circle")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
      }
      Text(isLoadingMore ? "Loading more sessions…" : "Loaded \(loadedSessionCount) sessions. Fetching more…")
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textTertiary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, layoutMode.isPhoneCompact ? Spacing.sm : Spacing.md)
    .padding(.top, Spacing.sm)
    .padding(.bottom, Spacing.lg)
  }

  // MARK: - Actions

  private func selectSession(_ session: RootSessionNode) {
    withAnimation(Motion.standard) {
      router.selectSession(session.sessionRef, source: .library)
    }
  }

  private func resetFilters() {
    providerFilter = .all
    selectedEndpointId = nil
  }

  private func loadMoreSessionsIfNeeded() async {
    guard hasMoreSessions else { return }
    guard !isLoadingMore else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }
    await onLoadMoreSessions()
  }
}
