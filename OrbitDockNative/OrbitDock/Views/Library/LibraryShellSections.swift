import SwiftUI

struct LibraryHeaderSection: View {
  let layoutMode: DashboardLayoutMode
  let scopeDescription: String
  let hasActiveFilters: Bool
  let summary: LibraryArchiveSummary
  let selectedEndpointFacet: LibraryEndpointFacet?
  let endpointFacets: [LibraryEndpointFacet]
  let providerScopedSessionCount: Int
  @Binding var searchText: String
  @Binding var sort: ActiveSessionSort
  @Binding var providerFilter: ActiveSessionProviderFilter
  @Binding var selectedEndpointId: UUID?

  var body: some View {
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

  private func filterSection(
    title: String,
    @ViewBuilder content: () -> some View
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
            count: providerScopedSessionCount,
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
}

struct LibraryEmptyState: View {
  let hasActiveFilters: Bool

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "books.vertical")
        .font(.system(size: 32, weight: .light))
        .foregroundStyle(Color.textQuaternary)

      Text(hasActiveFilters ? "No sessions match this slice" : "No sessions yet")
        .font(.system(size: TypeScale.subhead, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Text(
        hasActiveFilters
          ? "Try a different search, provider, or server filter."
          : "Sessions will show up here once OrbitDock has some history to archive."
      )
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textQuaternary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.vertical, 60)
  }
}
