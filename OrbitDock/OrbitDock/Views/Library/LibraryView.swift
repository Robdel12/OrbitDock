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
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

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

  private var providerScopedSessions: [Session] {
    switch providerFilter {
      case .all:
        sessions
      case .claude:
        sessions.filter { $0.provider == .claude }
      case .codex:
        sessions.filter { $0.provider == .codex }
    }
  }

  private var endpointFacets: [LibraryEndpointFacet] {
    buildEndpointFacets(from: providerScopedSessions)
  }

  private var endpointScopedSessions: [Session] {
    guard let selectedEndpointId,
          endpointFacets.contains(where: { $0.endpointId == selectedEndpointId })
    else {
      return providerScopedSessions
    }

    return providerScopedSessions.filter { $0.endpointId == selectedEndpointId }
  }

  private var filteredSessions: [Session] {
    guard !searchText.isEmpty else { return endpointScopedSessions }

    let query = searchText.lowercased()
    return endpointScopedSessions.filter { session in
      let fields = [
        session.displayName,
        session.projectName,
        session.projectPath,
        session.firstPrompt,
        session.lastMessage,
        session.branch,
        session.endpointName,
        session.model,
      ]
      .compactMap { $0?.lowercased() }

      return fields.contains { $0.contains(query) }
    }
  }

  private var summary: LibraryArchiveSummary {
    LibraryArchiveSummary(
      projectCount: Set(filteredSessions.map(\.groupingPath)).count,
      sessionCount: filteredSessions.count,
      liveCount: filteredSessions.filter(\.showsInMissionControl).count,
      endpointCount: Set(filteredSessions.compactMap(\.endpointId)).count
    )
  }

  private var selectedEndpointFacet: LibraryEndpointFacet? {
    guard let selectedEndpointId else { return nil }
    return endpointFacets.first(where: { $0.endpointId == selectedEndpointId })
  }

  private var hasActiveFilters: Bool {
    !searchText.isEmpty || providerFilter != .all || selectedEndpointFacet != nil
  }

  private var scopeDescription: String {
    var segments: [String] = []

    if let selectedEndpointFacet {
      segments.append(selectedEndpointFacet.name)
    } else if summary.endpointCount > 1 {
      segments.append("\(summary.endpointCount) servers")
    } else {
      segments.append("all servers")
    }

    if providerFilter != .all {
      segments.append(providerFilter.label)
    } else {
      segments.append("all providers")
    }

    segments.append("\(summary.sessionCount) sessions")
    return segments.joined(separator: " • ")
  }

  private var projectGroups: [LibraryProjectGroup] {
    let grouped = Dictionary(grouping: filteredSessions) { $0.groupingPath }

    return grouped.map { path, projectSessions in
      let name = projectSessions.first?.projectName
        ?? path.components(separatedBy: "/").last
        ?? "Unknown"

      let liveSessions = projectSessions
        .filter(\.showsInMissionControl)
        .sorted { activityDate(for: $0) > activityDate(for: $1) }

      let archivedSessions = projectSessions
        .filter { !$0.showsInMissionControl }
        .sorted { lhs, rhs in
          if lhs.isActive != rhs.isActive {
            return lhs.isActive && !rhs.isActive
          }
          return activityDate(for: lhs) > activityDate(for: rhs)
        }

      return LibraryProjectGroup(
        path: path,
        name: name,
        liveSessions: liveSessions,
        archivedSessions: archivedSessions,
        activeSessionCount: projectSessions.filter(\.isActive).count,
        totalCost: projectSessions.reduce(0.0) { $0 + $1.totalCostUSD },
        totalTokens: projectSessions.reduce(0) { $0 + $1.totalTokens },
        endpointFacets: buildEndpointFacets(from: projectSessions)
      )
    }
    .sorted { lhs, rhs in
      switch sort {
        case .recent:
          return lhs.latestActivity > rhs.latestActivity
        case .name:
          return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .cost:
          if lhs.totalCost != rhs.totalCost { return lhs.totalCost > rhs.totalCost }
          return lhs.latestActivity > rhs.latestActivity
        case .tokens:
          if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
          return lhs.latestActivity > rhs.latestActivity
        case .status:
          if lhs.liveSessions.count != rhs.liveSessions.count {
            return lhs.liveSessions.count > rhs.liveSessions.count
          }
          if lhs.cachedActiveSessionCount != rhs.cachedActiveSessionCount {
            return lhs.cachedActiveSessionCount > rhs.cachedActiveSessionCount
          }
          return lhs.latestActivity > rhs.latestActivity
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      libraryHeader

      if projectGroups.isEmpty {
        emptyState
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

  // MARK: - Header

  private var libraryHeader: some View {
    VStack(spacing: 0) {
      headerLayout
        .frame(maxWidth: layoutMode == .desktop ? 1_140 : .infinity, alignment: .leading)
        .padding(.horizontal, layoutMode.isPhoneCompact ? Spacing.md : Spacing.section)
        .padding(.top, layoutMode.isPhoneCompact ? Spacing.md_ : Spacing.md)
        .padding(.bottom, layoutMode.isPhoneCompact ? Spacing.md : Spacing.md_)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundSecondary)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
        .frame(height: 1)
    }
  }

  @ViewBuilder
  private var headerLayout: some View {
    switch layoutMode {
      case .phoneCompact:
        compactHeaderLayout
      case .pad:
        padHeaderLayout
      case .desktop:
        desktopHeaderLayout
    }
  }

  private var compactHeaderLayout: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      titleBlock
      utilityDeck
      summarySection
      filterRail
    }
  }

  private var padHeaderLayout: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Spacing.lg) {
          titleBlock
          Spacer(minLength: Spacing.md)
          utilityDeck
            .frame(width: 340)
        }

        VStack(alignment: .leading, spacing: Spacing.md) {
          titleBlock
          utilityDeck
        }
      }

      summarySection
      filterRail
    }
  }

  private var desktopHeaderLayout: some View {
    HStack(alignment: .top, spacing: Spacing.xl) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        titleBlock
        summarySection
        filterRail
      }

      Spacer(minLength: Spacing.xl)

      utilityDeck
        .frame(width: 350)
    }
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("ARCHIVE")
        .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
        .foregroundStyle(Color.accent)

      Text("Session Library")
        .font(.system(
          size: layoutMode.isPhoneCompact ? TypeScale.subhead : TypeScale.title,
          weight: .bold,
          design: .rounded
        ))
        .foregroundStyle(Color.textPrimary)

      Text("Search, slice, and compare the archive by project, provider, and server.")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)

      Text(scopeDescription)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(
          Capsule(style: .continuous)
            .fill(Color.backgroundPrimary.opacity(0.42))
            .overlay(
              Capsule(style: .continuous)
                .stroke(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
            )
        )
    }
  }

  private var utilityDeck: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm_) {
        Text("Find In Library")
          .font(.system(size: TypeScale.mini, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.textQuaternary)

        Spacer(minLength: Spacing.sm)

        if hasActiveFilters {
          Text("Filtered")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accent.opacity(OpacityTier.light), in: Capsule())
        }
      }

      searchField

      ViewThatFits(in: .horizontal) {
        HStack(spacing: Spacing.sm_) {
          sortMenu
          if hasActiveFilters {
            resetFiltersButton
          }
        }

        VStack(alignment: .leading, spacing: Spacing.sm_) {
          sortMenu
          if hasActiveFilters {
            resetFiltersButton
          }
        }
      }
    }
    .padding(layoutMode.isPhoneCompact ? Spacing.md_ : Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundPrimary.opacity(0.55))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
        )
    )
  }

  private var searchField: some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      TextField("Search sessions, branches, prompts, servers…", text: $searchText)
        .font(.system(size: TypeScale.caption))
        .textFieldStyle(.plain)

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, Spacing.sm)
    .background(
      Capsule(style: .continuous)
        .fill(Color.backgroundPrimary.opacity(0.55))
        .overlay(
          Capsule(style: .continuous)
            .stroke(Color.surfaceBorder.opacity(OpacityTier.medium), lineWidth: 1)
        )
    )
  }

  @ViewBuilder
  private var summarySection: some View {
    if layoutMode.isPhoneCompact {
      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: Spacing.sm),
          GridItem(.flexible(), spacing: Spacing.sm),
        ],
        spacing: Spacing.sm
      ) {
        summaryCards
      }
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Spacing.sm) {
          summaryCards
        }

        VStack(alignment: .leading, spacing: Spacing.sm) {
          HStack(spacing: Spacing.sm) {
            summaryCardProjects
            summaryCardSessions
          }
          HStack(spacing: Spacing.sm) {
            summaryCardLive
            summaryCardServers
          }
        }
      }
    }
  }

  private var filterRail: some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      HStack(spacing: Spacing.sm_) {
        Text("Refine Results")
          .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textQuaternary)

        if hasActiveFilters {
          Text("active filters")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.accent)
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Spacing.lg) {
          if !endpointFacets.isEmpty {
            filterSection(title: "Servers") {
              serverFilterChips
            }
          }

          filterSection(title: "Providers") {
            providerFilterStrip
          }
        }

        VStack(alignment: .leading, spacing: Spacing.md) {
          if !endpointFacets.isEmpty {
            filterSection(title: "Servers") {
              serverFilterChips
            }
          }

          filterSection(title: "Providers") {
            providerFilterStrip
          }
        }
      }
    }
    .padding(layoutMode.isPhoneCompact ? Spacing.md_ : Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundPrimary.opacity(0.3))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
        )
    )
  }

  private func filterSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      libraryFilterLabel(title)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var serverFilterChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm_) {
        Button {
          selectedEndpointId = nil
        } label: {
          LibraryFilterChip(
            title: "All Servers",
            count: providerScopedSessions.count,
            icon: "circle.grid.2x2.fill",
            tint: .accent,
            isSelected: selectedEndpointFacet == nil
          )
        }
        .buttonStyle(.plain)

        ForEach(endpointFacets) { facet in
          Button {
            selectedEndpointId = facet.endpointId
          } label: {
            LibraryFilterChip(
              title: facet.name,
              count: facet.sessionCount,
              icon: facet.isConnected ? "network" : "wifi.slash",
              tint: facet.isConnected ? .accent : .statusPermission,
              isSelected: selectedEndpointId == facet.endpointId
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.vertical, Spacing.xxs)
    }
  }

  private var providerFilterStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm_) {
        ForEach(ActiveSessionProviderFilter.allCases) { option in
          Button {
            providerFilter = option
          } label: {
            LibraryFilterChip(
              title: option.label,
              icon: option.icon,
              tint: option.color,
              isSelected: providerFilter == option
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var sortMenu: some View {
    Menu {
      ForEach(ActiveSessionSort.allCases) { option in
        Button {
          sort = option
        } label: {
          HStack {
            Text(option.label)
            if sort == option {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: sort.icon)
          .font(.system(size: TypeScale.micro, weight: .medium))
        Text("Sort: \(sort.label)")
          .font(.system(size: TypeScale.micro, weight: .semibold))
      }
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(
        Capsule(style: .continuous)
          .fill(Color.backgroundPrimary.opacity(0.4))
          .overlay(
            Capsule(style: .continuous)
              .stroke(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
          )
      )
    }
    .menuStyle(.borderlessButton)
  }

  private var resetFiltersButton: some View {
    Button {
      searchText = ""
      providerFilter = .all
      selectedEndpointId = nil
    } label: {
      Text("Reset")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          Capsule(style: .continuous)
            .fill(Color.backgroundPrimary.opacity(0.4))
        )
    }
    .buttonStyle(.plain)
  }

  private func libraryFilterLabel(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: TypeScale.mini, weight: .semibold, design: .rounded))
      .foregroundStyle(Color.textQuaternary)
  }

  @ViewBuilder
  private var summaryCards: some View {
    summaryCardProjects
    summaryCardSessions
    summaryCardLive
    summaryCardServers
  }

  private var summaryCardProjects: some View {
    LibrarySummaryCard(
      label: "Projects",
      value: "\(summary.projectCount)",
      accent: .accent,
      secondary: summary.projectCount == 1 ? "project" : "projects"
    )
  }

  private var summaryCardSessions: some View {
    LibrarySummaryCard(
      label: "Sessions",
      value: "\(summary.sessionCount)",
      accent: .textSecondary,
      secondary: "results"
    )
  }

  private var summaryCardLive: some View {
    LibrarySummaryCard(
      label: "Live",
      value: "\(summary.liveCount)",
      accent: .statusWorking,
      secondary: "connected"
    )
  }

  private var summaryCardServers: some View {
    LibrarySummaryCard(
      label: "Servers",
      value: "\(summary.endpointCount)",
      accent: .providerCodex,
      secondary: selectedEndpointFacet?.name ?? "in scope"
    )
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
                    text: formatCost(group.totalCost),
                    tint: .textSecondary
                  )
                }

                if group.totalTokens > 0 {
                  LibraryInlineStat(
                    text: formatTokens(group.totalTokens),
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

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "books.vertical")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(Color.textQuaternary)

      Text(hasActiveFilters ? "No sessions match this slice" : "No sessions yet")
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Text(hasActiveFilters ? "Try a different search, provider, or server filter." : "Sessions will show up here once OrbitDock has some history to archive.")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textQuaternary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.vertical, 60)
  }

  // MARK: - Navigation

  private func selectSession(_ session: Session) {
    withAnimation(Motion.standard) {
      router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
    }
  }

  // MARK: - Formatting

  private func activityDate(for session: Session) -> Date {
    session.lastActivityAt ?? session.endedAt ?? session.startedAt ?? .distantPast
  }

  private func buildEndpointFacets(from sessions: [Session]) -> [LibraryEndpointFacet] {
    let grouped: [UUID?: [Session]] = Dictionary(grouping: sessions) { $0.endpointId }

    return grouped
      .compactMap { (entry: (key: UUID?, value: [Session])) -> LibraryEndpointFacet? in
        guard let endpointId = entry.key else { return nil }
        let endpointSessions = entry.value
        let sortedSessions = endpointSessions.sorted { activityDate(for: $0) > activityDate(for: $1) }
        let endpointName = sortedSessions.compactMap(\.endpointName).first ?? "Endpoint"
        let isConnected = sortedSessions.contains { session in
          guard let status = session.endpointConnectionStatus else { return false }
          if case .connected = status { return true }
          return false
        }
        return LibraryEndpointFacet(
          endpointId: endpointId,
          name: endpointName,
          sessionCount: endpointSessions.count,
          isConnected: isConnected
        )
      }
      .sorted { lhs, rhs in
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame {
          return comparison == .orderedAscending
        }
        return lhs.endpointId.uuidString < rhs.endpointId.uuidString
      }
  }

  private func formatCost(_ cost: Double) -> String {
    if cost >= 100 { return String(format: "$%.0f", cost) }
    if cost >= 10 { return String(format: "$%.1f", cost) }
    return String(format: "$%.2f", cost)
  }

  private func formatTokens(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return "\(value)"
  }
}

// MARK: - Library Project Group

private struct LibraryProjectGroup: Identifiable {
  let path: String
  let name: String
  let liveSessions: [Session]
  let archivedSessions: [Session]
  let activeSessionCount: Int
  let totalCost: Double
  let totalTokens: Int
  let endpointFacets: [LibraryEndpointFacet]

  var id: String { path }

  var totalSessionCount: Int {
    liveSessions.count + archivedSessions.count
  }

  var cachedActiveSessionCount: Int {
    max(activeSessionCount - liveSessions.count, 0)
  }

  var latestActivity: Date {
    let allSessions = liveSessions + archivedSessions
    return allSessions.compactMap { $0.lastActivityAt ?? $0.startedAt }.max() ?? .distantPast
  }
}

private struct LibraryEndpointFacet: Identifiable, Hashable {
  let endpointId: UUID
  let name: String
  let sessionCount: Int
  let isConnected: Bool

  var id: UUID { endpointId }
}

private struct LibraryArchiveSummary {
  let projectCount: Int
  let sessionCount: Int
  let liveCount: Int
  let endpointCount: Int
}

private struct LibrarySummaryCard: View {
  let label: String
  let value: String
  let accent: Color
  let secondary: String

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(label.uppercased())
        .font(.system(size: TypeScale.mini, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textQuaternary)

      HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
        Text(value)
          .font(.system(size: TypeScale.body, weight: .bold, design: .rounded))
          .foregroundStyle(accent)

        Text(secondary)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundPrimary.opacity(0.45))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .stroke(accent.opacity(0.12), lineWidth: 1)
        )
    )
  }
}

private struct LibraryFilterChip: View {
  let title: String
  var count: Int? = nil
  var icon: String? = nil
  var tint: Color = .accent
  var isSelected: Bool

  var body: some View {
    HStack(spacing: Spacing.xs) {
      if let icon {
        Image(systemName: icon)
          .font(.system(size: TypeScale.mini, weight: .bold))
      }

      Text(title)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .lineLimit(1)

      if let count {
        Text("\(count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            Capsule(style: .continuous)
              .fill((isSelected ? tint : Color.surfaceHover).opacity(isSelected ? 0.22 : 0.55))
          )
      }
    }
    .foregroundStyle(isSelected ? tint : Color.textSecondary)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(
      Capsule(style: .continuous)
        .fill((isSelected ? tint : Color.backgroundPrimary).opacity(isSelected ? 0.16 : 0.32))
        .overlay(
          Capsule(style: .continuous)
            .stroke((isSelected ? tint : Color.surfaceBorder).opacity(isSelected ? 0.30 : OpacityTier.subtle), lineWidth: 1)
        )
    )
  }
}

private struct LibraryInlineStat: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
  }
}

private struct LibraryCountPill: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.surfaceHover.opacity(0.55), in: Capsule())
  }
}
