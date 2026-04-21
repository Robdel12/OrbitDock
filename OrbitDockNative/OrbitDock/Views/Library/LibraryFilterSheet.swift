//
//  LibraryFilterSheet.swift
//  OrbitDock
//
//  iOS filter sheet for library view (phoneCompact).
//  Provider + endpoint chips with reset, presented as a half-sheet.
//

import SwiftUI

struct LibraryFilterSheet: View {
  @Binding var providerFilter: ActiveSessionProviderFilter
  @Binding var selectedEndpointId: UUID?
  let endpointFacets: [LibraryEndpointFacet]
  let providerScopedSessionCount: Int
  let onReset: () -> Void
  @Environment(\.dismiss) private var dismiss

  private var hasActiveFilters: Bool {
    providerFilter != .all || selectedEndpointId != nil
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Provider section
        VStack(alignment: .leading, spacing: Spacing.sm) {
          sectionLabel("Provider")

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

        // Server section
        if endpointFacets.count > 1 {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("Server")

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
                    isSelected: selectedEndpointId == nil
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
            }
          }
        }

        Spacer()
      }
      .padding(Spacing.lg)
      .navigationTitle("Filters")
      .platformInlineNavigationTitle()
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
          ToolbarItem(placement: .cancellationAction) {
            if hasActiveFilters {
              Button("Reset") { onReset() }
            }
          }
        }
    }
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
      .foregroundStyle(Color.textQuaternary)
  }
}
