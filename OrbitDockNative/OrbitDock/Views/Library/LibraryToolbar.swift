//
//  LibraryToolbar.swift
//  OrbitDock
//
//  Compact toolbar for the library view. Search + sort + filters in a single bar.
//  Phone: search field + sort menu + filter sheet button.
//  Pad/Desktop: search field + inline sort/provider/endpoint menus.
//

import SwiftUI

struct LibraryToolbar: View {
  let layoutMode: DashboardLayoutMode
  let hasActiveFilters: Bool
  let summary: LibraryArchiveSummary
  let endpointFacets: [LibraryEndpointFacet]
  let providerScopedSessionCount: Int
  @Binding var searchText: String
  @Binding var sort: ActiveSessionSort
  @Binding var providerFilter: ActiveSessionProviderFilter
  @Binding var selectedEndpointId: UUID?
  @Binding var showFilterSheet: Bool

  private var isPhoneCompact: Bool {
    layoutMode.isPhoneCompact
  }

  private var hasEndpointFilter: Bool {
    selectedEndpointId != nil
  }

  private var selectedEndpointName: String? {
    guard let id = selectedEndpointId else { return nil }
    return endpointFacets.first { $0.endpointId == id }?.name
  }

  private var activeFilterCount: Int {
    var count = 0
    if providerFilter != .all { count += 1 }
    if selectedEndpointId != nil { count += 1 }
    return count
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Spacing.sm) {
        searchField

        if isPhoneCompact {
          compactSortMenu
          filterSheetButton
        } else {
          sortMenu
          providerMenu
          if endpointFacets.count > 1 {
            endpointMenu
          }
          if hasActiveFilters {
            clearButton
          }
        }

        if layoutMode == .desktop {
          Spacer(minLength: Spacing.sm)
          inlineSummaryStats
        }
      }
      .padding(.horizontal, isPhoneCompact ? Spacing.md : Spacing.section)
      .padding(.vertical, Spacing.sm)

      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
        .frame(height: 1)
    }
    .background(Color.backgroundSecondary)
  }

  // MARK: - Search

  private var searchField: some View {
    HStack(spacing: Spacing.sm_) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      TextField("Search sessions or ID…", text: $searchText)
        .font(.system(size: isPhoneCompact ? TypeScale.caption : TypeScale.body))
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
    .frame(maxWidth: layoutMode == .desktop ? 350 : .infinity)
  }

  // MARK: - Compact Controls (phoneCompact)

  private var compactSortMenu: some View {
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
      Image(systemName: sort.icon)
        .font(.system(size: TypeScale.meta, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .padding(Spacing.sm_)
        .background(
          Circle()
            .fill(Color.backgroundPrimary.opacity(0.55))
            .overlay(
              Circle()
                .stroke(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
            )
        )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var filterSheetButton: some View {
    Button {
      showFilterSheet = true
    } label: {
      ZStack(alignment: .topTrailing) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(activeFilterCount > 0 ? Color.accent : Color.textTertiary)
          .padding(Spacing.sm_)
          .background(
            Circle()
              .fill(Color.backgroundPrimary.opacity(0.55))
              .overlay(
                Circle()
                  .stroke(
                    (activeFilterCount > 0 ? Color.accent : Color.surfaceBorder)
                      .opacity(activeFilterCount > 0 ? 0.30 : OpacityTier.subtle),
                    lineWidth: 1
                  )
              )
          )

        if activeFilterCount > 0 {
          Circle()
            .fill(Color.accent)
            .frame(width: 7, height: 7)
            .offset(x: -1, y: 1)
        }
      }
    }
    .buttonStyle(.plain)
  }

  // MARK: - Inline Controls (pad/desktop)

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
      toolbarControl(icon: sort.icon, label: sort.label)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var providerMenu: some View {
    Menu {
      ForEach(ActiveSessionProviderFilter.allCases) { option in
        Button {
          providerFilter = option
        } label: {
          HStack {
            Text(option.label)
            if providerFilter == option {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      toolbarControl(
        icon: "line.3.horizontal.decrease.circle",
        label: providerFilter == .all ? "Provider" : providerFilter.label,
        isActive: providerFilter != .all
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var endpointMenu: some View {
    Menu {
      Button {
        selectedEndpointId = nil
      } label: {
        HStack {
          Text("All Servers")
          if selectedEndpointId == nil {
            Image(systemName: "checkmark")
          }
        }
      }

      ForEach(endpointFacets) { facet in
        Button {
          selectedEndpointId = facet.endpointId
        } label: {
          HStack {
            Text("\(facet.name) (\(facet.sessionCount))")
            if selectedEndpointId == facet.endpointId {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      toolbarControl(
        icon: "server.rack",
        label: selectedEndpointName ?? "Servers",
        isActive: hasEndpointFilter
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  // MARK: - Inline Summary (desktop)

  private var inlineSummaryStats: some View {
    HStack(spacing: Spacing.md) {
      inlineStat("\(summary.sessionCount) sessions", tint: .textTertiary)
      if summary.liveCount > 0 {
        inlineStat("\(summary.liveCount) live", tint: .statusWorking)
      }
    }
  }

  private func inlineStat(_ text: String, tint: Color) -> some View {
    Text(text)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
  }

  // MARK: - Clear

  private var clearButton: some View {
    Button {
      searchText = ""
      providerFilter = .all
      selectedEndpointId = nil
    } label: {
      Text("Clear")
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.textTertiary.opacity(0.10), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Helpers

  private func toolbarControl(icon: String, label: String, isActive: Bool = false) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.micro, weight: .medium))
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .semibold))
    }
    .foregroundStyle(isActive ? Color.accent : Color.textTertiary)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm_)
    .background(
      Capsule(style: .continuous)
        .fill(Color.backgroundPrimary.opacity(0.34))
    )
  }
}
