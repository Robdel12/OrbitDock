//
//  DashboardToolbar.swift
//  OrbitDock
//
//  Single-line toolbar with signal pills (left) and sort/filter controls (right).
//  Extracted from ProjectStreamSection to keep the toolbar pinned above the scroll view.
//

import SwiftUI

struct DashboardToolbar: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  let sessions: [Session]
  @Binding var filter: ActiveSessionWorkbenchFilter
  @Binding var sort: ActiveSessionSort
  @Binding var providerFilter: ActiveSessionProviderFilter
  @Binding var projectGroupOrder: [String]
  @Binding var useCustomProjectOrder: Bool
  @Binding var hiddenProjectGroups: Set<String>
  @Binding var sessionOrderByGroup: [String: [String]]
  @Binding var isEditMode: Bool
  let projectGroups: [ProjectGroup]

  private var allActiveSessions: [Session] {
    sessions.filter(\.isActive)
  }

  private var counts: ToolbarTriageCounts {
    ToolbarTriageCounts(sessions: allActiveSessions)
  }

  private var directCount: Int {
    allActiveSessions.filter(\.isDirect).count
  }

  private var claudeCount: Int {
    allActiveSessions.filter { $0.provider == .claude }.count
  }

  private var codexCount: Int {
    allActiveSessions.filter { $0.provider == .codex }.count
  }

  private var hiddenProjectCount: Int {
    hiddenProjectGroups.count
  }

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var isPhoneCompact: Bool {
    layoutMode.isPhoneCompact
  }

  private var hasAnySignalCounts: Bool {
    counts.attention > 0 || counts.running > 0 || counts.ready > 0 || directCount > 0
  }

  private var hasAnyProviderCounts: Bool {
    claudeCount > 0 || codexCount > 0
  }

  private var hasSignals: Bool {
    hasAnySignalCounts || hasAnyProviderCounts
      || filter != .all || providerFilter != .all
  }

  var body: some View {
    if isPhoneCompact {
      compactToolbar
    } else {
      regularToolbar
    }
  }

  // MARK: - Regular (Desktop/Pad) Toolbar

  private var regularToolbar: some View {
    HStack(spacing: Spacing.sm_) {
      if isEditMode {
        editModeToolbar
      } else {
        // Signal pills (left)
        if hasSignals {
          signalPills
        }

        Spacer(minLength: Spacing.xs)

        // Controls (right) — unified style
        HStack(spacing: Spacing.xxs) {
          sortPicker
          filterDropdown
          projectManagementMenu
        }

        // State pills
        if useCustomProjectOrder {
          toolbarStatePill(
            label: "Custom Order",
            color: Color.accent,
            action: { useCustomProjectOrder = false }
          )
          .help("Custom project order overrides sort. Click to use sort order.")
        }

        if filter != .all || providerFilter != .all {
          toolbarStatePill(
            label: "Clear",
            color: Color.textTertiary,
            action: {
              filter = .all
              providerFilter = .all
            }
          )
        }

        if hiddenProjectCount > 0 {
          toolbarStatePill(
            label: "Show \(hiddenProjectCount) Hidden",
            color: Color.textTertiary,
            action: { hiddenProjectGroups.removeAll() }
          )
        }
      }
    }
    .padding(.horizontal, Spacing.lg_)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundSecondary.opacity(0.5))
  }

  private func toolbarStatePill(label: String, color: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, Spacing.sm_)
        .padding(.vertical, Spacing.gap)
        .background(color.opacity(0.10), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Compact (Phone) Toolbar

  private var compactToolbar: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      HStack(spacing: Spacing.sm) {
        Text("Active Agents")
          .font(.system(size: TypeScale.subhead, weight: .bold))
          .foregroundStyle(.primary)

        Text("\(allActiveSessions.count)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, 7)
          .padding(.vertical, Spacing.xxs)
          .background(Color.surfaceHover.opacity(0.6), in: Capsule())

        Spacer()

        if isEditMode {
          doneButton
        } else {
          compactFilterMenu

          Button {
            enterEditMode()
          } label: {
            Image(systemName: "pencil")
              .font(.system(size: TypeScale.meta, weight: .semibold))
              .foregroundStyle(Color.textSecondary)
              .frame(width: 28, height: 28)
              .background(
                Color.surfaceHover.opacity(0.5),
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              )
          }
          .buttonStyle(.plain)

          if useCustomProjectOrder {
            Button {
              useCustomProjectOrder = false
            } label: {
              Text("Custom")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.gap)
                .background(Color.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
          }
        }

        if filter != .all || providerFilter != .all {
          Button {
            filter = .all
            providerFilter = .all
          } label: {
            Text("Clear")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.gap)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())
          }
          .buttonStyle(.plain)
        }

        if hiddenProjectCount > 0 {
          Button {
            hiddenProjectGroups.removeAll()
          } label: {
            Text("Show \(hiddenProjectCount)")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.gap)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }

      if !isEditMode, hasSignals {
        compactSignalGrid
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundSecondary.opacity(0.7))
  }

  // MARK: - Edit Mode

  private var editModeToolbar: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "arrow.up.and.down.text.horizontal")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.accent)

      Text("Drag to reorder, tap")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Image(systemName: "eye.slash")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Text("to hide")
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Spacer()

      doneButton
    }
  }

  private var doneButton: some View {
    Button {
      withAnimation(Motion.standard) {
        isEditMode = false
      }
    } label: {
      Text("Done")
        .font(.system(size: TypeScale.meta, weight: .semibold))
        .foregroundStyle(Color.accent)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 5)
        .background(Color.accent.opacity(0.15), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  private func enterEditMode() {
    withAnimation(Motion.standard) {
      if !useCustomProjectOrder {
        projectGroupOrder = mergedProjectOrder(withVisible: projectGroups.map(\.groupKey))
      }
      useCustomProjectOrder = true
      isEditMode = true
    }
  }

  // MARK: - Signal Pills

  private var signalPills: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.xs) {
        if counts.attention > 0 || filter == .attention {
          signalPill(
            target: .attention,
            icon: "exclamationmark.circle.fill",
            title: "Attn",
            count: counts.attention,
            color: .statusPermission
          )
        }

        if counts.running > 0 || filter == .running {
          signalPill(
            target: .running,
            icon: "bolt.fill",
            title: "Running",
            count: counts.running,
            color: .statusWorking
          )
        }

        if counts.ready > 0 || filter == .ready {
          signalPill(
            target: .ready,
            icon: "bubble.left.fill",
            title: "Ready",
            count: counts.ready,
            color: .statusReply
          )
        }

        if directCount > 0 || filter == .direct {
          directPill
        }

        // Subtle divider between signal + provider pills
        if hasAnySignalCounts, hasAnyProviderCounts {
          Circle()
            .fill(Color.textQuaternary)
            .frame(width: 2, height: 2)
            .padding(.horizontal, Spacing.xxs)
        }

        providerPills
      }
      .padding(.vertical, Spacing.xxs)
    }
  }

  private func signalPill(
    target: ActiveSessionWorkbenchFilter,
    icon: String,
    title: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = filter == target

    return Button {
      filter = isActive ? .all : target
    } label: {
      HStack(spacing: Spacing.gap) {
        Image(systemName: icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(color)

        Text("\(count)")
          .font(.system(size: TypeScale.meta, weight: .bold, design: .rounded))
          .foregroundStyle(isActive ? color : Color.textSecondary)

        Text(title)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(isActive ? color : Color.textTertiary)
      }
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.gap)
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

  private var directPill: some View {
    let isDirectActive = filter == .direct

    return Button {
      filter = isDirectActive ? .all : .direct
    } label: {
      HStack(spacing: Spacing.gap) {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.providerCodex)

        Text("\(directCount)")
          .font(.system(size: TypeScale.meta, weight: .bold, design: .rounded))
          .foregroundStyle(isDirectActive ? Color.providerCodex : Color.textSecondary)

        Text("Direct")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(isDirectActive ? Color.providerCodex : Color.textTertiary)
      }
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.gap)
      .background(
        Capsule()
          .fill(
            (isDirectActive ? Color.providerCodex : Color.surfaceHover)
              .opacity(isDirectActive ? 0.18 : 0.35)
          )
          .overlay(
            Capsule()
              .stroke(
                Color.providerCodex.opacity(isDirectActive ? 0.30 : 0.0),
                lineWidth: 1
              )
          )
      )
    }
    .buttonStyle(.plain)
  }

  private var providerPills: some View {
    HStack(spacing: Spacing.xs) {
      providerPill(target: .claude, label: "Claude", count: claudeCount, color: .accent)
      providerPill(target: .codex, label: "Codex", count: codexCount, color: .providerCodex)
    }
  }

  private func providerPill(
    target: ActiveSessionProviderFilter,
    label: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = providerFilter == target

    return Button {
      providerFilter = isActive ? .all : target
    } label: {
      HStack(spacing: Spacing.gap) {
        Image(systemName: target.icon)
          .font(.system(size: 7, weight: .bold))
        Text("\(label) \(count)")
          .font(.system(size: TypeScale.micro, weight: .medium))
      }
      .foregroundStyle(isActive ? color : Color.textQuaternary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.gap)
      .background(
        Capsule()
          .fill((isActive ? color : Color.surfaceHover).opacity(isActive ? 0.18 : 0.25))
          .overlay(
            Capsule()
              .stroke(color.opacity(isActive ? 0.30 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Compact Signal Grid

  private var compactSignalGrid: some View {
    let columns = [
      GridItem(.flexible(minimum: 120), spacing: Spacing.sm_),
      GridItem(.flexible(minimum: 120), spacing: Spacing.sm_),
    ]

    return LazyVGrid(columns: columns, spacing: Spacing.sm_) {
      if counts.attention > 0 || filter == .attention {
        compactSignalChip(
          target: .attention,
          icon: "exclamationmark.circle.fill",
          title: "Needs review",
          count: counts.attention,
          color: .statusPermission
        )
      }

      if counts.running > 0 || filter == .running {
        compactSignalChip(
          target: .running,
          icon: "bolt.fill",
          title: "Running",
          count: counts.running,
          color: .statusWorking
        )
      }

      if counts.ready > 0 || filter == .ready {
        compactSignalChip(
          target: .ready,
          icon: "bubble.left.fill",
          title: "Ready",
          count: counts.ready,
          color: .statusReply
        )
      }

      if directCount > 0 || filter == .direct {
        compactSignalChip(
          target: .direct,
          icon: "chevron.left.forwardslash.chevron.right",
          title: "Direct",
          count: directCount,
          color: .providerCodex
        )
      }

      if providerFilter != .all {
        compactProviderChip
          .gridCellColumns(2)
      }
    }
  }

  private func compactSignalChip(
    target: ActiveSessionWorkbenchFilter,
    icon: String,
    title: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = filter == target

    return Button {
      filter = isActive ? .all : target
    } label: {
      HStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: TypeScale.mini, weight: .bold))

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: TypeScale.micro, weight: .semibold))
          Text("\(count)")
            .font(.system(size: TypeScale.meta, weight: .bold, design: .rounded))
        }

        Spacer(minLength: 0)
      }
      .foregroundStyle(isActive ? color : color.opacity(0.78))
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(isActive ? color.opacity(0.18) : color.opacity(0.10))
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(color.opacity(isActive ? 0.30 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .help(target.title)
  }

  private var compactProviderChip: some View {
    let color = providerFilter.color
    let isActive = providerFilter != .all

    return Button {
      providerFilter = isActive ? .all : providerFilter
    } label: {
      HStack(spacing: 5) {
        Image(systemName: providerFilter.icon)
          .font(.system(size: TypeScale.mini, weight: .bold))
        Text(providerFilter.label)
          .font(.system(size: TypeScale.micro, weight: .semibold))
        Spacer(minLength: 0)
        Text("filtered")
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .rounded))
      }
      .foregroundStyle(isActive ? color : Color.textTertiary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm_)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill((isActive ? color : Color.surfaceHover).opacity(isActive ? 0.18 : 0.5))
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(color.opacity(isActive ? 0.25 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .help("Provider filter active")
  }

  // MARK: - Sort & Filter Controls

  private var sortPicker: some View {
    Menu {
      ForEach(ActiveSessionSort.allCases) { option in
        Button {
          sort = option
          useCustomProjectOrder = false
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
      toolbarControl(icon: sort.icon, label: sort.label, isActive: false)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var filterDropdown: some View {
    let isActive = filter != .all || providerFilter != .all

    return Menu {
      Section("State") {
        ForEach(ActiveSessionWorkbenchFilter.allCases) { option in
          Button {
            filter = option
          } label: {
            HStack {
              Text(option.title)
              if filter == option {
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
      toolbarControl(icon: "line.3.horizontal.decrease.circle", label: "Filter", isActive: isActive)
    }
    .menuStyle(.borderlessButton)
  }

  private var projectManagementMenu: some View {
    let isActive = !projectGroupOrder.isEmpty || hiddenProjectCount > 0

    return Menu {
      Section("Projects") {
        Button {
          useCustomProjectOrder = false
        } label: {
          Label(
            "Use Sort Order",
            systemImage: useCustomProjectOrder ? "line.3.horizontal.decrease.circle" : "checkmark"
          )
        }
        .disabled(!useCustomProjectOrder)

        Button {
          useCustomProjectOrder = true
        } label: {
          Label(
            "Use Custom Order",
            systemImage: useCustomProjectOrder ? "checkmark" : "arrow.up.and.down.and.arrow.left.and.right"
          )
        }
        .disabled(projectGroupOrder.isEmpty || useCustomProjectOrder)

        Divider()

        Button {
          enterEditMode()
        } label: {
          Label("Edit Projects\u{2026}", systemImage: "arrow.up.and.down.text.horizontal")
        }

        Button {
          projectGroupOrder.removeAll()
          useCustomProjectOrder = false
        } label: {
          Label("Reset Custom Order", systemImage: "arrow.uturn.backward")
        }
        .disabled(projectGroupOrder.isEmpty)

        Button {
          sessionOrderByGroup.removeAll()
        } label: {
          Label("Reset Session Order", systemImage: "arrow.uturn.backward.circle")
        }
        .disabled(sessionOrderByGroup.isEmpty)

        Button {
          hiddenProjectGroups.removeAll()
        } label: {
          Label("Show Hidden Projects", systemImage: "eye")
        }
        .disabled(hiddenProjectCount == 0)
      }
    } label: {
      toolbarControl(icon: "folder", label: "Projects", isActive: isActive)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private func toolbarControl(icon: String, label: String, isActive: Bool) -> some View {
    HStack(spacing: Spacing.gap) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.mini, weight: .medium))
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
    }
    .foregroundStyle(isActive ? Color.accent : Color.textTertiary)
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.xs)
  }

  // MARK: - Compact Filter Menu

  private var compactFilterMenu: some View {
    Menu {
      Section("Sort") {
        ForEach(ActiveSessionSort.allCases) { option in
          Button {
            sort = option
            useCustomProjectOrder = false
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

      Section("State") {
        ForEach(ActiveSessionWorkbenchFilter.allCases) { option in
          Button {
            filter = option
          } label: {
            HStack {
              Text(option.title)
              if filter == option {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }

      Section("Projects") {
        Button {
          useCustomProjectOrder = false
        } label: {
          HStack {
            Text("Use Sort Order")
            if !useCustomProjectOrder {
              Image(systemName: "checkmark")
            }
          }
        }

        Button {
          useCustomProjectOrder = true
        } label: {
          HStack {
            Text("Use Custom Order")
            if useCustomProjectOrder {
              Image(systemName: "checkmark")
            }
          }
        }
        .disabled(projectGroupOrder.isEmpty && !useCustomProjectOrder)

        Button {
          enterEditMode()
        } label: {
          Text("Edit Projects\u{2026}")
        }

        Button {
          projectGroupOrder.removeAll()
          useCustomProjectOrder = false
        } label: {
          HStack {
            Text("Reset Custom Order")
            if projectGroupOrder.isEmpty {
              Image(systemName: "checkmark")
            }
          }
        }

        Button {
          sessionOrderByGroup.removeAll()
        } label: {
          Text("Reset Session Order")
        }
        .disabled(sessionOrderByGroup.isEmpty)

        Button {
          hiddenProjectGroups.removeAll()
        } label: {
          HStack {
            Text("Show Hidden Projects")
            if hiddenProjectCount == 0 {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .font(.system(size: TypeScale.meta, weight: .semibold))
        Text("Filter")
          .font(.system(size: TypeScale.micro, weight: .semibold))
      }
      .foregroundStyle((filter != .all || providerFilter != .all) ? Color.accent : Color.textSecondary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(Color.surfaceHover.opacity(0.5), in: Capsule())
    }
    .menuStyle(.borderlessButton)
  }

  // MARK: - Helpers

  private func mergedProjectOrder(withVisible visibleKeys: [String]) -> [String] {
    var merged: [String] = []
    var seen: Set<String> = []

    for key in visibleKeys where seen.insert(key).inserted {
      merged.append(key)
    }

    for key in projectGroupOrder where seen.insert(key).inserted {
      merged.append(key)
    }

    return merged
  }
}

// MARK: - Triage Counts

private struct ToolbarTriageCounts {
  var attention = 0
  var running = 0
  var ready = 0

  init(sessions: [Session]) {
    for session in sessions {
      let status = SessionDisplayStatus.from(session)
      switch status {
        case .permission, .question: attention += 1
        case .working: running += 1
        case .reply: ready += 1
        case .ended: break
      }
    }
  }
}
