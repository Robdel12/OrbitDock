//
//  ActivityStreamToolbar.swift
//  OrbitDock
//
//  Horizontal filter chips + sort controls for the activity stream.
//  Mobile-first: single scrollable chip row on phone, inline on desktop.
//

import SwiftUI

struct ActivityStreamToolbar: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  let sessions: [Session]
  @Binding var filter: ActiveSessionWorkbenchFilter
  @Binding var sort: ActiveSessionSort
  @Binding var providerFilter: ActiveSessionProviderFilter

  private var allActiveSessions: [Session] {
    sessions.filter(\.showsInMissionControl)
  }

  private var counts: DashboardTriageCounts {
    DashboardTriageCounts(sessions: allActiveSessions)
  }

  private var directCount: Int {
    allActiveSessions.filter(\.isDirect).count
  }

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var isPhoneCompact: Bool {
    layoutMode.isPhoneCompact
  }

  private var hasAnyFilters: Bool {
    filter != .all || providerFilter != .all
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      filterChips

      Spacer(minLength: Spacing.sm_)

      if !isPhoneCompact {
        HStack(spacing: Spacing.xs) {
          sortPicker
          providerMenu
        }
      }

      if hasAnyFilters {
        clearButton
      }
    }
    .padding(.horizontal, isPhoneCompact ? Spacing.md : Spacing.section)
    .padding(.vertical, Spacing.sm_)
    .background(Color.backgroundSecondary.opacity(0.3))
  }

  // MARK: - Filter Chips

  private var filterChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm_) {
        filterChip(target: .all, icon: nil, label: "All", count: allActiveSessions.count, color: .textSecondary)

        if counts.attention > 0 || filter == .attention {
          filterChip(target: .attention, icon: "exclamationmark.circle.fill", label: "Attn", count: counts.attention, color: .statusPermission)
        }

        if counts.running > 0 || filter == .running {
          filterChip(target: .running, icon: "bolt.fill", label: "Running", count: counts.running, color: .statusWorking)
        }

        if counts.ready > 0 || filter == .ready {
          filterChip(target: .ready, icon: "bubble.left.fill", label: "Ready", count: counts.ready, color: .statusReply)
        }

        if directCount > 0 || filter == .direct {
          filterChip(target: .direct, icon: "chevron.left.forwardslash.chevron.right", label: "Direct", count: directCount, color: .providerCodex)
        }

        if isPhoneCompact {
          compactSortMenu
        }
      }
      .padding(.vertical, Spacing.xxs)
    }
  }

  private func filterChip(
    target: ActiveSessionWorkbenchFilter,
    icon: String?,
    label: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = filter == target

    return Button {
      filter = isActive ? .all : target
    } label: {
      HStack(spacing: Spacing.xs) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(isActive ? color : color.opacity(0.6))
        }

        Text("\(count)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
          .foregroundStyle(isActive ? color : Color.textSecondary)

        Text(label)
          .font(.system(size: TypeScale.micro, weight: .semibold))
      }
      .foregroundStyle(isActive ? color : Color.textTertiary)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(
        Capsule()
          .fill((isActive ? color : Color.surfaceHover).opacity(isActive ? 0.18 : 0.35))
          .overlay(
            Capsule()
              .stroke(color.opacity(isActive ? 0.30 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Sort

  private var sortPicker: some View {
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

  private var compactSortMenu: some View {
    Menu {
      Section("Sort") {
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
      }

      Section("Provider") {
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
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: TypeScale.meta, weight: .medium))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, Spacing.sm_)
        .padding(.vertical, Spacing.sm_)
    }
    .menuStyle(.borderlessButton)
  }

  // MARK: - Clear

  private var clearButton: some View {
    Button {
      filter = .all
      providerFilter = .all
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
    .padding(.vertical, Spacing.sm)
  }
}
