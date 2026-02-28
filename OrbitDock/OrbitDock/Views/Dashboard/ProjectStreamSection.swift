//
//  ProjectStreamSection.swift
//  OrbitDock
//
//  Project-first flat session layout. Groups active sessions by project directory,
//  with branches shown inline per session row. Replaces lane-based triage grouping
//  with a developer-centric project-first mental model.
//

import SwiftUI
import UniformTypeIdentifiers

struct ProjectStreamSection: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(ServerAppState.self) private var serverState
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let sessions: [Session]
  var selectedIndex: Int?
  @Binding var filter: ActiveSessionWorkbenchFilter
  @Binding var sort: ActiveSessionSort
  @Binding var providerFilter: ActiveSessionProviderFilter
  @Binding var projectGroupOrder: [String]
  @Binding var useCustomProjectOrder: Bool
  @Binding var hiddenProjectGroups: Set<String>

  @State private var worktreeSheetGroup: WorktreeSheetIdentifier?
  @State private var draggingProjectGroupKey: String?
  @State private var collapsedProjectGroups: Set<String> = []
  @State private var collapseForReorder = false

  private var filteredSessions: [Session] {
    Self.filteredSessions(
      from: sessions,
      filter: filter,
      sort: sort,
      providerFilter: providerFilter
    )
  }

  private var projectGroups: [ProjectGroup] {
    Self.makeProjectGroups(
      from: filteredSessions,
      sort: sort,
      preferredOrder: useCustomProjectOrder ? projectGroupOrder : [],
      hiddenGroupKeys: hiddenProjectGroups
    )
  }

  private var orderedSessions: [Session] {
    projectGroups.flatMap(\.sessions)
  }

  private var sessionIndexByID: [String: Int] {
    Dictionary(uniqueKeysWithValues: orderedSessions.enumerated().map { ($1.scopedID, $0) })
  }

  private var allActiveSessions: [Session] {
    Self.sortedActiveSessions(from: sessions, sort: sort)
  }

  private var hiddenProjectCount: Int {
    hiddenProjectGroups.count
  }

  private var counts: ProjectStreamTriageCounts {
    ProjectStreamTriageCounts(sessions: allActiveSessions)
  }

  private var directCount: Int {
    allActiveSessions.filter(\.isDirect).count
  }

  private var passiveCount: Int {
    max(0, allActiveSessions.count - directCount)
  }

  private var claudeCount: Int {
    allActiveSessions.filter { $0.provider == .claude }.count
  }

  private var codexCount: Int {
    allActiveSessions.filter { $0.provider == .codex }.count
  }

  private var attentionSessions: [Session] {
    allActiveSessions.filter { SessionDisplayStatus.from($0).needsAttention }
  }

  private var runningSessions: [Session] {
    allActiveSessions.filter { SessionDisplayStatus.from($0) == .working }
  }

  private var readySessions: [Session] {
    allActiveSessions.filter { SessionDisplayStatus.from($0) == .reply }
  }

  private var oldestAttentionSession: Session? {
    attentionSessions.min { Self.sortDate($0) < Self.sortDate($1) }
  }

  private var oldestReadySession: Session? {
    readySessions.min { Self.sortDate($0) < Self.sortDate($1) }
  }

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var isPhoneCompact: Bool {
    layoutMode.isPhoneCompact
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader

      if projectGroups.isEmpty {
        emptyState
      } else {
        VStack(spacing: Spacing.md) {
          ForEach(projectGroups) { group in
            projectSection(group)
              .contentShape(Rectangle())
              .onDrag {
                dragItemProvider(for: group)
              } preview: {
                projectDragPreview(for: group)
              }
              .onDrop(
                of: [UTType.text],
                delegate: ProjectGroupDropDelegate(
                  destinationKey: group.groupKey,
                  orderedVisibleKeys: reorderableGroupKeys,
                  projectGroupOrder: $projectGroupOrder,
                  useCustomProjectOrder: $useCustomProjectOrder,
                  collapseForReorder: $collapseForReorder,
                  draggingGroupKey: $draggingProjectGroupKey
                )
              )
          }
        }
        .padding(.top, 4)
      }
    }
    .sheet(item: $worktreeSheetGroup) { group in
      WorktreeListView(
        repoRoot: group.repoRoot,
        projectName: group.projectName,
        onDismiss: { worktreeSheetGroup = nil },
        onCreateClaudeSession: { cwd in
          worktreeSheetGroup = nil
          serverState.createClaudeSession(cwd: cwd)
        },
        onCreateCodexSession: { cwd in
          worktreeSheetGroup = nil
          serverState.createSession(cwd: cwd)
        }
      )
    }
  }

  // MARK: - Public Ordering API

  static func keyboardNavigableSessions(
    from sessions: [Session],
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort = .status,
    providerFilter: ActiveSessionProviderFilter = .all,
    projectGroupOrder: [String] = [],
    useCustomProjectOrder: Bool = true,
    hiddenProjectGroups: Set<String> = []
  ) -> [Session] {
    let filtered = filteredSessions(
      from: sessions,
      filter: filter,
      sort: sort,
      providerFilter: providerFilter
    )
    let groups = makeProjectGroups(
      from: filtered,
      sort: sort,
      preferredOrder: useCustomProjectOrder ? projectGroupOrder : [],
      hiddenGroupKeys: hiddenProjectGroups
    )
    return groups.flatMap(\.sessions)
  }

  // MARK: - Section Header

  @ViewBuilder
  private var sectionHeader: some View {
    if isPhoneCompact {
      phoneCompactSectionHeader
    } else {
      regularSectionHeader
    }
  }

  private var regularSectionHeader: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Active Sessions")
          .font(.system(size: TypeScale.headline, weight: .bold))
          .foregroundStyle(.primary)
          .tracking(-0.35)

        Text("\(orderedSessions.count)")
          .font(.system(size: TypeScale.subhead, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textSecondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.surfaceHover.opacity(0.7), in: Capsule())

        if let pulse = operationsPulse {
          HStack(spacing: 4) {
            Circle()
              .fill(pulse.color)
              .frame(width: 6, height: 6)
            Text(pulse.label)
              .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
          }
          .foregroundStyle(pulse.color)
          .padding(.horizontal, 9)
          .padding(.vertical, 4)
          .background(pulse.color.opacity(0.12), in: Capsule())
        }
      }

      regularSignalRail

      HStack(spacing: 0) {
        sortPicker
        thinSeparator

        filterDropdown
        thinSeparator
        projectManagementMenu

        Spacer()

        if useCustomProjectOrder {
          Button {
            useCustomProjectOrder = false
          } label: {
            Text("Custom Order")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color.accent)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.accent.opacity(0.12), in: Capsule())
          }
          .buttonStyle(.plain)
          .help("Custom project order overrides sort. Click to use sort order.")
          .padding(.trailing, 6)
        }

        if collapseForReorder {
          Button {
            draggingProjectGroupKey = nil
            collapseForReorder = false
          } label: {
            Text("Exit Reorder")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.surfaceHover.opacity(0.55), in: Capsule())
          }
          .buttonStyle(.plain)
          .padding(.trailing, 6)
        }

        if filter != .all || providerFilter != .all {
          Button {
            filter = .all
            providerFilter = .all
          } label: {
            Text("Clear")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())
          }
          .buttonStyle(.plain)
        }

        if hiddenProjectCount > 0 {
          Button {
            hiddenProjectGroups.removeAll()
          } label: {
            Text("Show Hidden \(hiddenProjectCount)")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())
          }
          .buttonStyle(.plain)
          .padding(.leading, 6)
        }
      }
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 2)
  }

  private var phoneCompactSectionHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Active Agents")
          .font(.system(size: TypeScale.subhead, weight: .bold))
          .foregroundStyle(.primary)

        Text("\(orderedSessions.count)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Color.surfaceHover.opacity(0.6), in: Capsule())

        Spacer()

        compactFilterMenu

        if useCustomProjectOrder {
          Button {
            useCustomProjectOrder = false
          } label: {
            Text("Custom")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Color.accent)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.accent.opacity(0.12), in: Capsule())
          }
          .buttonStyle(.plain)
        }

        if collapseForReorder {
          Button {
            draggingProjectGroupKey = nil
            collapseForReorder = false
          } label: {
            Text("Done")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())
          }
          .buttonStyle(.plain)
        }

        if filter != .all || providerFilter != .all {
          Button {
            filter = .all
            providerFilter = .all
          } label: {
            Text("Clear")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())
          }
          .buttonStyle(.plain)
        }

        if hiddenProjectCount > 0 {
          Button {
            hiddenProjectGroups.removeAll()
          } label: {
            Text("Show \(hiddenProjectCount)")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(Color.surfaceHover.opacity(0.5), in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }

      if shouldShowCompactSignalRow {
        LazyVGrid(columns: compactSignalColumns, spacing: 6) {
          if counts.attention > 0 || filter == .attention {
            compactSignalFilterChip(
              target: .attention,
              icon: "exclamationmark.circle.fill",
              title: "Needs review",
              count: counts.attention,
              color: .statusPermission
            )
          }

          if counts.running > 0 || filter == .running {
            compactSignalFilterChip(
              target: .running,
              icon: "bolt.fill",
              title: "Running",
              count: counts.running,
              color: .statusWorking
            )
          }

          if counts.ready > 0 || filter == .ready {
            compactSignalFilterChip(
              target: .ready,
              icon: "bubble.left.fill",
              title: "Ready",
              count: counts.ready,
              color: .statusReply
            )
          }

          if directCount > 0 || filter == .direct {
            compactSignalFilterChip(
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
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 2)
  }

  private var compactSignalColumns: [GridItem] {
    [
      GridItem(.flexible(minimum: 120), spacing: 6),
      GridItem(.flexible(minimum: 120), spacing: 6),
    ]
  }

  private var shouldShowCompactSignalRow: Bool {
    counts.attention > 0 || counts.running > 0 || counts
      .ready > 0 || directCount > 0 || filter != .all || providerFilter != .all
  }

  private var operationsPulse: (label: String, color: Color)? {
    guard !orderedSessions.isEmpty else { return nil }
    if counts.attention >= 3 {
      return ("Intervene", .statusPermission)
    }
    if counts.attention > 0 {
      return ("Watch", .statusQuestion)
    }
    if counts.running > 0 {
      return ("Flowing", .statusWorking)
    }
    if counts.ready > 0 {
      return ("Awaiting Input", .statusReply)
    }
    return ("Quiet", .textTertiary)
  }

  @ViewBuilder
  private var regularSignalRail: some View {
    if counts.attention > 0 || counts.running > 0 || counts
      .ready > 0 || directCount > 0 || filter != .all || providerFilter != .all
    {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          regularSignalPill(
            target: .attention,
            icon: "exclamationmark.circle.fill",
            title: "Needs Attention",
            detail: attentionSignalDetail,
            count: counts.attention,
            color: .statusPermission
          )

          regularSignalPill(
            target: .running,
            icon: "bolt.fill",
            title: "Running",
            detail: runningSignalDetail,
            count: counts.running,
            color: .statusWorking
          )

          regularSignalPill(
            target: .ready,
            icon: "bubble.left.fill",
            title: "Ready",
            detail: readySignalDetail,
            count: counts.ready,
            color: .statusReply
          )

          regularDirectControlPill
          regularProviderRail
        }
        .padding(.vertical, 2)
      }
    }
  }

  private func regularSignalPill(
    target: ActiveSessionWorkbenchFilter,
    icon: String,
    title: String,
    detail: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = filter == target

    return Button {
      filter = isActive ? .all : target
    } label: {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(color)

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(.primary)
          Text(detail)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)
        }

        Text("\(count)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
          .foregroundStyle(color)
          .padding(.leading, 2)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill((isActive ? color : Color.surfaceHover).opacity(isActive ? 0.20 : 0.45))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(color.opacity(isActive ? 0.35 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private var regularDirectControlPill: some View {
    let isDirectActive = filter == .direct

    return Button {
      filter = isDirectActive ? .all : .direct
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.providerCodex)

        VStack(alignment: .leading, spacing: 1) {
          Text("Control Mode")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(.primary)
          Text("\(directCount) direct · \(passiveCount) passive")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textTertiary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill((isDirectActive ? Color.providerCodex : Color.surfaceHover).opacity(isDirectActive ? 0.20 : 0.45))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.providerCodex.opacity(isDirectActive ? 0.35 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private var regularProviderRail: some View {
    HStack(spacing: 6) {
      regularProviderPill(
        target: .claude,
        label: "Claude",
        count: claudeCount,
        color: .accent
      )
      regularProviderPill(
        target: .codex,
        label: "Codex",
        count: codexCount,
        color: .providerCodex
      )
    }
  }

  private func regularProviderPill(
    target: ActiveSessionProviderFilter,
    label: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = providerFilter == target

    return Button {
      providerFilter = isActive ? .all : target
    } label: {
      HStack(spacing: 5) {
        Image(systemName: target.icon)
          .font(.system(size: 8, weight: .bold))
        Text(label)
          .font(.system(size: TypeScale.micro, weight: .semibold))
        Text("\(count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
      }
      .foregroundStyle(isActive ? color : Color.textTertiary)
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill((isActive ? color : Color.surfaceHover).opacity(isActive ? 0.20 : 0.45))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(color.opacity(isActive ? 0.35 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private var attentionSignalDetail: String {
    if let oldestAttentionSession {
      return "Oldest \(relativeTimestamp(for: oldestAttentionSession))"
    }
    return "No blocked work"
  }

  private var runningSignalDetail: String {
    if counts.running == 0 {
      return "No active runs"
    }
    return "\(counts.running) in motion"
  }

  private var readySignalDetail: String {
    if let oldestReadySession {
      return "Oldest \(relativeTimestamp(for: oldestReadySession))"
    }
    return "No reply queue"
  }

  private func relativeTimestamp(for session: Session) -> String {
    let activity = session.lastActivityAt ?? session.startedAt ?? .distantPast
    let interval = Date().timeIntervalSince(activity)

    if interval < 60 {
      return "under a minute"
    }
    if interval < 3_600 {
      let minutes = Int(interval / 60)
      return "\(minutes)m"
    }
    if interval < 86_400 {
      let hours = Int(interval / 3_600)
      let minutes = Int(interval.truncatingRemainder(dividingBy: 3_600) / 60)
      return "\(hours)h \(minutes)m"
    }
    let days = Int(interval / 86_400)
    return "\(days)d"
  }

  // MARK: - Sort Picker

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
      HStack(spacing: 4) {
        Image(systemName: sort.icon)
          .font(.system(size: 9, weight: .semibold))
        Text(sort.label)
          .font(.system(size: 10, weight: .medium))
      }
      .foregroundStyle(Color.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.surfaceHover.opacity(0.4), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var projectManagementMenu: some View {
    Menu {
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
          projectGroupOrder.removeAll()
          useCustomProjectOrder = false
        } label: {
          Label("Reset Custom Order", systemImage: "arrow.uturn.backward")
        }
        .disabled(projectGroupOrder.isEmpty)

        Button {
          hiddenProjectGroups.removeAll()
        } label: {
          Label("Show Hidden Projects", systemImage: "eye")
        }
        .disabled(hiddenProjectCount == 0)
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "folder.badge.gearshape")
          .font(.system(size: 10, weight: .semibold))
        Text("Projects")
          .font(.system(size: 10, weight: .medium))
      }
      .foregroundStyle((!projectGroupOrder.isEmpty || hiddenProjectCount > 0) ? Color.accent : Color.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.surfaceHover.opacity(0.4), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  // MARK: - Provider Toggle

  private var providerToggle: some View {
    HStack(spacing: 2) {
      ForEach(ActiveSessionProviderFilter.allCases) { option in
        Button {
          providerFilter = providerFilter == option ? .all : option
        } label: {
          HStack(spacing: 3) {
            if option != .all {
              Image(systemName: option.icon)
                .font(.system(size: 8, weight: .bold))
            }
            Text(option.label)
              .font(.system(size: 10, weight: providerFilter == option ? .bold : .medium))
          }
          .foregroundStyle(providerFilter == option ? option.color : Color.textTertiary)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(
            providerFilter == option ? option.color.opacity(OpacityTier.light) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
          )
        }
        .buttonStyle(.plain)
      }
    }
  }

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
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .font(.system(size: 11, weight: .semibold))
        Text("Filter")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundStyle((filter != .all || providerFilter != .all) ? Color.accent : Color.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.surfaceHover.opacity(0.5), in: Capsule())
    }
    .menuStyle(.borderlessButton)
  }

  private var compactProviderChip: some View {
    let color = providerFilter.color
    let isActive = providerFilter != .all

    return Button {
      providerFilter = isActive ? .all : providerFilter
    } label: {
      HStack(spacing: 5) {
        Image(systemName: providerFilter.icon)
          .font(.system(size: 9, weight: .bold))
        Text(providerFilter.label)
          .font(.system(size: 10, weight: .semibold))
        Spacer(minLength: 0)
        Text("filtered")
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .rounded))
      }
      .foregroundStyle(isActive ? color : Color.textTertiary)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
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

  private func compactSignalFilterChip(
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
          .font(.system(size: 9, weight: .bold))

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: TypeScale.micro, weight: .semibold))
          Text("\(count)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
        }

        Spacer(minLength: 0)
      }
      .foregroundStyle(isActive ? color : color.opacity(0.78))
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
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

  private var filterDropdown: some View {
    Menu {
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
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .font(.system(size: 11, weight: .semibold))
        Text("Filter")
          .font(.system(size: TypeScale.caption, weight: .semibold))
      }
      .foregroundStyle((filter != .all || providerFilter != .all) ? Color.accent : Color.textSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.surfaceHover.opacity(0.5), in: Capsule())
    }
    .menuStyle(.borderlessButton)
  }

  private var thinSeparator: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(0.2))
      .frame(width: 1, height: 14)
      .padding(.horizontal, 8)
  }

  private func filterChip(
    target: ActiveSessionWorkbenchFilter,
    icon: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = filter == target

    return Button {
      filter = filter == target ? .all : target
    } label: {
      HStack(spacing: 4) {
        Image(systemName: icon)
          .font(.system(size: 9, weight: .bold))
        Text("\(count)")
          .font(.system(size: 10, weight: .bold, design: .rounded))
      }
      .foregroundStyle(isActive ? color : color.opacity(0.75))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(isActive ? color.opacity(0.20) : color.opacity(0.08))
          .overlay(
            Capsule()
              .stroke(color.opacity(isActive ? 0.30 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
    .help(target.title)
  }

  private var reorderableGroupKeys: [String] {
    let visibleKeys = projectGroups.map(\.groupKey)
    let preferredVisible = projectGroupOrder.filter { visibleKeys.contains($0) }
    let missingVisible = visibleKeys.filter { !preferredVisible.contains($0) }
    return preferredVisible + missingVisible
  }

  private var projectActionKeys: [String] {
    if useCustomProjectOrder {
      return reorderableGroupKeys
    }
    return projectGroups.map(\.groupKey)
  }

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

  private func projectActionsMenu(_ group: ProjectGroup) -> some View {
    let keys = projectActionKeys
    let index = keys.firstIndex(of: group.groupKey) ?? 0
    let lastIndex = max(0, keys.count - 1)

    return Menu {
      Button {
        moveProject(group, to: 0)
      } label: {
        Label("Move To Top", systemImage: "arrow.up.to.line")
      }
      .disabled(index == 0 || keys.count <= 1)

      Button {
        moveProject(group, by: -1)
      } label: {
        Label("Move Up", systemImage: "arrow.up")
      }
      .disabled(index == 0 || keys.count <= 1)

      Button {
        moveProject(group, by: 1)
      } label: {
        Label("Move Down", systemImage: "arrow.down")
      }
      .disabled(index >= lastIndex || keys.count <= 1)

      Button {
        moveProject(group, to: lastIndex)
      } label: {
        Label("Move To Bottom", systemImage: "arrow.down.to.line")
      }
      .disabled(index >= lastIndex || keys.count <= 1)

      Divider()

      Button(role: .destructive) {
        hideProject(group)
      } label: {
        Label("Hide Project", systemImage: "eye.slash")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)
    }
    .menuStyle(.borderlessButton)
    .help("Project actions")
  }

  private func moveProject(_ group: ProjectGroup, by delta: Int) {
    let keys = useCustomProjectOrder ? reorderableGroupKeys : projectActionKeys
    guard let index = keys.firstIndex(of: group.groupKey) else { return }
    let targetIndex = min(max(index + delta, 0), max(0, keys.count - 1))
    moveProject(group, to: targetIndex)
  }

  private func moveProject(_ group: ProjectGroup, to destinationIndex: Int) {
    var keys = useCustomProjectOrder ? reorderableGroupKeys : mergedProjectOrder(withVisible: projectGroups.map(\.groupKey))
    guard let index = keys.firstIndex(of: group.groupKey) else { return }

    let boundedDestination = min(max(destinationIndex, 0), max(0, keys.count - 1))
    guard boundedDestination != index else { return }

    let movedKey = keys.remove(at: index)
    keys.insert(movedKey, at: boundedDestination)
    projectGroupOrder = keys
    useCustomProjectOrder = true
  }

  private func hideProject(_ group: ProjectGroup) {
    if !useCustomProjectOrder {
      projectGroupOrder = mergedProjectOrder(withVisible: projectGroups.map(\.groupKey))
    }
    hiddenProjectGroups.insert(group.groupKey)
    projectGroupOrder.removeAll { $0 == group.groupKey }
    useCustomProjectOrder = true
  }

  private func dragItemProvider(for group: ProjectGroup) -> NSItemProvider {
    withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
      if !useCustomProjectOrder {
        projectGroupOrder = mergedProjectOrder(withVisible: projectGroups.map(\.groupKey))
      }
      draggingProjectGroupKey = group.groupKey
      useCustomProjectOrder = true
      collapseForReorder = true
    }
    return NSItemProvider(object: group.groupKey as NSString)
  }

  private func projectDragPreview(for group: ProjectGroup) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.textQuaternary)

      Text(group.projectName)
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Text("\(group.sessions.count)")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.surfaceHover.opacity(0.75), in: Capsule())
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.92))
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(Color.panelBorder.opacity(0.55), lineWidth: 1)
        )
    )
  }

  private func isProjectCollapsed(_ group: ProjectGroup) -> Bool {
    if collapseForReorder {
      return true
    }
    return collapsedProjectGroups.contains(group.groupKey)
  }

  private func toggleProjectCollapsed(_ group: ProjectGroup) {
    if collapsedProjectGroups.contains(group.groupKey) {
      collapsedProjectGroups.remove(group.groupKey)
    } else {
      collapsedProjectGroups.insert(group.groupKey)
    }
  }

  // MARK: - Project Section

  private func projectSection(_ group: ProjectGroup) -> some View {
    let sharedBranch = group.sharedBranch
    let projectSignals = projectSignalCounts(for: group.sessions)
    let worktreeCount = group.sessions.filter(\.isWorktree).count
    let repoRoot = group.sessions.compactMap(\.repositoryRoot).first
    let isCollapsed = isProjectCollapsed(group)
    let isReorderCompacting = collapseForReorder

    return VStack(alignment: .leading, spacing: 0) {
      // Project divider rule
      Rectangle()
        .fill(Color.surfaceBorder.opacity(0.2))
        .frame(height: 1)
        .padding(.horizontal, 4)
        .padding(.top, isReorderCompacting ? 4 : 10)

      // Project header
      Group {
        if isPhoneCompact {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Button {
                toggleProjectCollapsed(group)
              } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundStyle(Color.textQuaternary)
                  .frame(width: 12, height: 12)
              }
              .buttonStyle(.plain)

              Text(group.projectName)
                .font(.system(size: TypeScale.subhead, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

              // Shared branch — shown here when all sessions are on the same branch
              if !isReorderCompacting, let branch = sharedBranch {
                Text(branch.count > 22 ? String(branch.prefix(20)) + "…" : branch)
                  .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                  .foregroundStyle(Color.gitBranch.opacity(0.7))
                  .lineLimit(1)
              }

              Text("\(group.sessions.count) \(group.sessions.count == 1 ? "agent" : "agents")")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.textQuaternary)

              Spacer()

              projectActionsMenu(group)
            }

            if !isReorderCompacting && (projectSignals.attention > 0 || projectSignals.running > 0 || projectSignals
              .ready > 0 || projectSignals.direct > 0)
            {
              HStack(spacing: 5) {
                if projectSignals.attention > 0 {
                  projectSignalChip(
                    icon: "exclamationmark.circle.fill",
                    count: projectSignals.attention,
                    color: .statusPermission
                  )
                }

                if projectSignals.running > 0 {
                  projectSignalChip(
                    icon: "bolt.fill",
                    count: projectSignals.running,
                    color: .statusWorking
                  )
                }

                if projectSignals.ready > 0 {
                  projectSignalChip(
                    icon: "bubble.left.fill",
                    count: projectSignals.ready,
                    color: .statusReply
                  )
                }

                if projectSignals.direct > 0 {
                  projectSignalChip(
                    icon: "chevron.left.forwardslash.chevron.right",
                    count: projectSignals.direct,
                    color: .providerCodex
                  )
                }

                if let repoRoot {
                  worktreeButton(repoRoot: repoRoot, projectName: group.projectName, count: worktreeCount)
                }
              }
            }
          }
        } else {
          HStack(spacing: 8) {
            Button {
              toggleProjectCollapsed(group)
            } label: {
              Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.textQuaternary)
                .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)

            Text(group.projectName)
              .font(.system(size: TypeScale.large, weight: .bold))
              .foregroundStyle(.primary)

            // Shared branch — shown here when all sessions are on the same branch
            if !isReorderCompacting, let branch = sharedBranch {
              Text(branch.count > 28 ? String(branch.prefix(26)) + "…" : branch)
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.gitBranch.opacity(0.7))
            }

            Text("\(group.sessions.count) \(group.sessions.count == 1 ? "agent" : "agents")")
              .font(.system(size: 10, weight: .medium, design: .rounded))
              .foregroundStyle(Color.textQuaternary)

            if !isReorderCompacting, projectSignals.attention > 0 {
              projectSignalChip(
                icon: "exclamationmark.circle.fill",
                count: projectSignals.attention,
                color: .statusPermission
              )
            }

            if !isReorderCompacting, projectSignals.running > 0 {
              projectSignalChip(
                icon: "bolt.fill",
                count: projectSignals.running,
                color: .statusWorking
              )
            }

            if !isReorderCompacting, projectSignals.ready > 0 {
              projectSignalChip(
                icon: "bubble.left.fill",
                count: projectSignals.ready,
                color: .statusReply
              )
            }

            if !isReorderCompacting, projectSignals.direct > 0 {
              projectSignalChip(
                icon: "chevron.left.forwardslash.chevron.right",
                count: projectSignals.direct,
                color: .providerCodex
              )
            }

            if !isReorderCompacting, let repoRoot {
              worktreeButton(repoRoot: repoRoot, projectName: group.projectName, count: worktreeCount)
            }

            projectActionsMenu(group)

            Spacer()

            if !isReorderCompacting, group.totalTokens > 0 {
              Text(formatTokens(group.totalTokens))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
            }
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, isReorderCompacting ? 8 : 14)
      .padding(.bottom, isReorderCompacting ? 2 : 4)

      if !isCollapsed {
        // Worktree strip (between header and session rows)
        // Use group.projectPath as the key — matches sidebar's worktree loading
        // pattern and works even when sessions don't have repositoryRoot set.
        InlineWorktreeStrip(
          repoRoot: group.projectPath,
          projectName: group.projectName,
          allSessions: sessions,
          onCreateClaudeSession: { cwd in serverState.createClaudeSession(cwd: cwd) },
          onCreateCodexSession: { cwd in serverState.createSession(cwd: cwd) },
          onOpenManageSheet: {
            worktreeSheetGroup = WorktreeSheetIdentifier(
              repoRoot: group.projectPath,
              projectName: group.projectName
            )
          }
        )

        // Session rows
        VStack(spacing: 2) {
          ForEach(group.sessions, id: \.scopedID) { session in
            let rowIndex = sessionIndexByID[session.scopedID]
            let isSelected = rowIndex == selectedIndex

            FlatSessionRow(
              session: session,
              onSelect: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                  router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
                }
              },
              isSelected: isSelected,
              hideBranch: sharedBranch != nil
            )
            .flatSessionScrollID(rowIndex)
          }
        }
      }
    }
  }

  private func projectSignalCounts(for sessions: [Session]) -> ProjectStatusCounts {
    var counts = ProjectStatusCounts()
    for session in sessions {
      let status = SessionDisplayStatus.from(session)
      switch status {
        case .permission, .question:
          counts.attention += 1
        case .working:
          counts.running += 1
        case .reply:
          counts.ready += 1
        case .ended:
          break
      }
      if session.isDirect {
        counts.direct += 1
      }
    }
    return counts
  }

  private func projectSignalChip(icon: String, count: Int, color: Color) -> some View {
    HStack(spacing: 3) {
      Image(systemName: icon)
        .font(.system(size: 8, weight: .bold))
      Text("\(count)")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
    }
    .foregroundStyle(color)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(color.opacity(0.10), in: Capsule())
  }

  private func worktreeButton(repoRoot: String, projectName: String, count: Int) -> some View {
    let color: Color = count > 0 ? .gitBranch : .textQuaternary
    return Button {
      worktreeSheetGroup = WorktreeSheetIdentifier(
        repoRoot: repoRoot,
        projectName: projectName
      )
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 8, weight: .bold))
        if count > 0 {
          Text("\(count)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        }
      }
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(color.opacity(0.10), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(Color.backgroundTertiary)
          .frame(width: 50, height: 50)

        Image(systemName: "cpu")
          .font(.system(size: 20, weight: .light))
          .foregroundStyle(Color.textTertiary)
      }

      VStack(spacing: 4) {
        if filter != .all {
          Text("No \(filter.title) Sessions")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
          Text("Try a different filter or clear the current one.")
            .font(.system(size: 11))
            .foregroundStyle(Color.textTertiary)
        } else {
          Text("No Active Sessions")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.textSecondary)

          Text("Start an AI coding session to see it here.")
            .font(.system(size: 11))
            .foregroundStyle(Color.textTertiary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
  }

  // MARK: - Data Builders

  private static func filteredSessions(
    from sessions: [Session],
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort = .status,
    providerFilter: ActiveSessionProviderFilter = .all
  ) -> [Session] {
    let active = sortedActiveSessions(from: sessions, sort: sort)
    let providerFiltered = applyProviderFilter(active, filter: providerFilter)
    return applyWorkbenchFilter(providerFiltered, filter: filter)
  }

  private static func sortedActiveSessions(from sessions: [Session], sort: ActiveSessionSort = .status) -> [Session] {
    sessions
      .filter(\.isActive)
      .sorted { lhs, rhs in compareSessions(lhs: lhs, rhs: rhs, sort: sort) }
  }

  private static func applyProviderFilter(_ sessions: [Session], filter: ActiveSessionProviderFilter) -> [Session] {
    switch filter {
      case .all: sessions
      case .claude: sessions.filter { $0.provider == .claude }
      case .codex: sessions.filter { $0.provider == .codex }
    }
  }

  private static func applyWorkbenchFilter(_ sessions: [Session], filter: ActiveSessionWorkbenchFilter) -> [Session] {
    switch filter {
      case .all: sessions
      case .direct: sessions.filter(\.isDirect)
      case .attention: sessions.filter { SessionDisplayStatus.from($0).needsAttention }
      case .running: sessions.filter { SessionDisplayStatus.from($0) == .working }
      case .ready: sessions.filter { SessionDisplayStatus.from($0) == .reply }
    }
  }

  static func makeProjectGroups(
    from sessions: [Session],
    sort: ActiveSessionSort = .status,
    preferredOrder: [String] = [],
    hiddenGroupKeys: Set<String> = []
  ) -> [ProjectGroup] {
    struct GroupBucketKey: Hashable {
      let endpointScope: String
      let path: String

      var groupKey: String {
        "\(endpointScope)::\(path)"
      }
    }

    // Merge subdirectory paths into their parent project.
    // e.g., sessions in /foo/bar and /foo/bar/sub both group under /foo/bar.
    // But don't merge into overly generic parent paths like ~/Developer.
    // Use groupingPath (repositoryRoot ?? projectPath) so worktree sessions
    // group with their parent repo instead of appearing as separate projects.
    let pathsByEndpointScope = Dictionary(grouping: sessions) { $0.endpointId?.uuidString ?? "single-endpoint" }
      .mapValues { Set($0.map(\.groupingPath)) }
    let canonicalPath: (Session) -> String = { session in
      let path = session.groupingPath
      let endpointScope = session.endpointId?.uuidString ?? "single-endpoint"
      let allPaths = pathsByEndpointScope[endpointScope] ?? []

      let parentCandidates = allPaths
        .filter { $0 != path && path.hasPrefix($0 + "/") }
        .sorted { lhs, rhs in
          let lhsComponents = lhs.components(separatedBy: "/").filter { !$0.isEmpty }.count
          let rhsComponents = rhs.components(separatedBy: "/").filter { !$0.isEmpty }.count
          if lhsComponents != rhsComponents { return lhsComponents < rhsComponents }
          return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

      // Only merge into candidates that look like actual project dirs (4+ components)
      // e.g., /Users/name/Developer/project — not /Users/name/Developer
      for candidate in parentCandidates {
        let candidateComponents = candidate.components(separatedBy: "/").filter { !$0.isEmpty }
        if candidateComponents.count >= 4 {
          return candidate
        }
      }
      return path
    }

    let grouped = Dictionary(grouping: sessions) { session -> GroupBucketKey in
      let path = canonicalPath(session)
      let endpointScope = session.endpointId?.uuidString ?? "single-endpoint"
      return GroupBucketKey(endpointScope: endpointScope, path: path)
    }

    let projectGroups: [ProjectGroup] = grouped.compactMap {
      (bucketKey: GroupBucketKey, projectSessions: [Session]) -> ProjectGroup? in
      guard let first = projectSessions.first else { return nil }

      let sortedSessions = projectSessions.sorted { lhs, rhs in
        compareSessions(lhs: lhs, rhs: rhs, sort: sort)
      }
      let path = bucketKey.path
      let projectName = first.projectName ?? path.components(separatedBy: "/").last ?? "Unknown"

      return ProjectGroup(
        groupKey: bucketKey.groupKey,
        projectPath: path,
        projectName: projectName,
        endpointName: first.endpointName,
        sessions: sortedSessions,
        totalCost: sortedSessions.reduce(0) { $0 + $1.totalCostUSD },
        totalTokens: sortedSessions.reduce(0) { $0 + $1.totalTokens },
        latestActivityAt: sortedSessions.map { $0.lastActivityAt ?? $0.startedAt ?? .distantPast }.max() ?? .distantPast
      )
    }
    .filter { !hiddenGroupKeys.contains($0.groupKey) }

    let naturallySortedGroups = projectGroups.sorted { lhs, rhs in
      compareProjectGroups(lhs: lhs, rhs: rhs, sort: sort)
    }

    guard !preferredOrder.isEmpty else {
      return naturallySortedGroups
    }

    var preferredIndexes: [String: Int] = [:]
    for groupKey in preferredOrder where preferredIndexes[groupKey] == nil {
      preferredIndexes[groupKey] = preferredIndexes.count
    }

    return naturallySortedGroups.sorted { lhs, rhs in
      let lhsIndex = preferredIndexes[lhs.groupKey]
      let rhsIndex = preferredIndexes[rhs.groupKey]

      switch (lhsIndex, rhsIndex) {
        case let (left?, right?):
          if left != right { return left < right }
          return compareProjectGroups(lhs: lhs, rhs: rhs, sort: sort)
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          return compareProjectGroups(lhs: lhs, rhs: rhs, sort: sort)
      }
    }
  }

  private static func compareSessions(lhs: Session, rhs: Session, sort: ActiveSessionSort) -> Bool {
    switch sort {
      case .status:
        let lhsPriority = statusPriority(SessionDisplayStatus.from(lhs))
        let rhsPriority = statusPriority(SessionDisplayStatus.from(rhs))
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return sortDate(lhs) > sortDate(rhs)

      case .recent:
        return sortDate(lhs) > sortDate(rhs)

      case .tokens:
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return sortDate(lhs) > sortDate(rhs)

      case .cost:
        if lhs.totalCostUSD != rhs.totalCostUSD { return lhs.totalCostUSD > rhs.totalCostUSD }
        return sortDate(lhs) > sortDate(rhs)
    }
  }

  private static func compareProjectGroups(lhs: ProjectGroup, rhs: ProjectGroup, sort: ActiveSessionSort) -> Bool {
    switch sort {
      case .status:
        let lhsPriority = lhs.sessions.map { statusPriority(SessionDisplayStatus.from($0)) }.min() ?? Int.max
        let rhsPriority = rhs.sessions.map { statusPriority(SessionDisplayStatus.from($0)) }.min() ?? Int.max
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        if lhs.latestActivityAt != rhs.latestActivityAt { return lhs.latestActivityAt > rhs.latestActivityAt }
        return compareProjectGroupTiebreakers(lhs: lhs, rhs: rhs)

      case .recent:
        if lhs.latestActivityAt != rhs.latestActivityAt { return lhs.latestActivityAt > rhs.latestActivityAt }
        return compareProjectGroupTiebreakers(lhs: lhs, rhs: rhs)

      case .tokens:
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        if lhs.latestActivityAt != rhs.latestActivityAt { return lhs.latestActivityAt > rhs.latestActivityAt }
        return compareProjectGroupTiebreakers(lhs: lhs, rhs: rhs)

      case .cost:
        if lhs.totalCost != rhs.totalCost { return lhs.totalCost > rhs.totalCost }
        if lhs.latestActivityAt != rhs.latestActivityAt { return lhs.latestActivityAt > rhs.latestActivityAt }
        return compareProjectGroupTiebreakers(lhs: lhs, rhs: rhs)
    }
  }

  private static func compareProjectGroupTiebreakers(lhs: ProjectGroup, rhs: ProjectGroup) -> Bool {
    let nameOrder = lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName)
    if nameOrder != .orderedSame {
      return nameOrder == .orderedAscending
    }
    let endpointOrder = (lhs.endpointName ?? "").localizedCaseInsensitiveCompare(rhs.endpointName ?? "")
    if endpointOrder != .orderedSame {
      return endpointOrder == .orderedAscending
    }
    return lhs.projectPath.localizedCaseInsensitiveCompare(rhs.projectPath) == .orderedAscending
  }

  static func statusPriority(_ status: SessionDisplayStatus) -> Int {
    switch status {
      case .permission: 0
      case .question: 1
      case .working: 2
      case .reply: 3
      case .ended: 4
    }
  }

  static func sortDate(_ session: Session) -> Date {
    session.lastActivityAt ?? session.startedAt ?? .distantPast
  }

  // MARK: - Formatting

  private func formatTokens(_ value: Int) -> String {
    if value <= 0 { return "" }
    if value >= 1_000_000 {
      return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fk", Double(value) / 1_000)
    }
    return "\(value)"
  }

  private func formatCost(_ value: Double) -> String {
    if value <= 0 { return "" }
    if value < 1 { return String(format: "$%.2f", value) }
    return String(format: "$%.1f", value)
  }
}

// MARK: - Project Group Model

struct ProjectGroup: Identifiable {
  let groupKey: String
  let projectPath: String
  let projectName: String
  let endpointName: String?
  let sessions: [Session]
  let totalCost: Double
  let totalTokens: Int
  let latestActivityAt: Date

  var id: String {
    groupKey
  }

  /// When all sessions share the same branch, return it for the header.
  /// Returns nil if branches differ or are missing.
  var sharedBranch: String? {
    let branches = Set(sessions.compactMap(\.branch).filter { !$0.isEmpty })
    guard branches.count == 1, let branch = branches.first else { return nil }
    return branch
  }
}

// MARK: - Triage Counts (reusable)

private struct ProjectStatusCounts {
  var attention = 0
  var running = 0
  var ready = 0
  var direct = 0
}

private struct ProjectStreamTriageCounts {
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

// MARK: - Scroll ID

extension View {
  @ViewBuilder
  func flatSessionScrollID(_ index: Int?) -> some View {
    if let index {
      self.id("active-session-\(index)")
    } else {
      self
    }
  }
}

// Filter types defined in ActiveSessionsSection.swift

// MARK: - Worktree Sheet Identifier

private struct WorktreeSheetIdentifier: Identifiable {
  let repoRoot: String
  let projectName: String
  var id: String {
    repoRoot
  }
}

private struct ProjectGroupDropDelegate: DropDelegate {
  let destinationKey: String
  let orderedVisibleKeys: [String]
  @Binding var projectGroupOrder: [String]
  @Binding var useCustomProjectOrder: Bool
  @Binding var collapseForReorder: Bool
  @Binding var draggingGroupKey: String?

  func dropEntered(info _: DropInfo) {
    guard let draggingKey = draggingGroupKey, draggingKey != destinationKey else { return }

    var normalizedKeys = normalizedOrderKeys()
    guard let fromIndex = normalizedKeys.firstIndex(of: draggingKey),
          let toIndex = normalizedKeys.firstIndex(of: destinationKey),
          fromIndex != toIndex
    else { return }

    let movedKey = normalizedKeys.remove(at: fromIndex)
    normalizedKeys.insert(movedKey, at: toIndex)
    projectGroupOrder = normalizedKeys
    useCustomProjectOrder = true
  }

  func dropUpdated(info _: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info _: DropInfo) -> Bool {
    withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
      draggingGroupKey = nil
      collapseForReorder = false
    }
    return true
  }

  private func normalizedOrderKeys() -> [String] {
    var normalized: [String] = []
    var seen: Set<String> = []

    for key in projectGroupOrder {
      if seen.insert(key).inserted {
        normalized.append(key)
      }
    }

    for key in orderedVisibleKeys where !seen.contains(key) {
      seen.insert(key)
      normalized.append(key)
    }

    return normalized
  }
}

// MARK: - Preview

#Preview {
  @Previewable @State var filter: ActiveSessionWorkbenchFilter = .all
  @Previewable @State var sort: ActiveSessionSort = .status
  @Previewable @State var providerFilter: ActiveSessionProviderFilter = .all
  @Previewable @State var projectGroupOrder: [String] = []
  @Previewable @State var useCustomProjectOrder = false
  @Previewable @State var hiddenProjectGroups: Set<String> = []

  ScrollView {
    ProjectStreamSection(
      sessions: [
        Session(
          id: "1",
          projectPath: "/Users/dev/claude-dashboard",
          projectName: "claude-dashboard",
          branch: "main",
          model: "claude-opus-4-5-20251101",
          summary: "Refactoring layout",
          status: .active,
          workStatus: .working,
          startedAt: Date().addingTimeInterval(-2_460),
          totalTokens: 7_600,
          totalCostUSD: 2.50
        ),
        Session(
          id: "2",
          projectPath: "/Users/dev/claude-dashboard",
          projectName: "claude-dashboard",
          branch: "main",
          model: "claude-sonnet-4-20250514",
          summary: "Running tests",
          status: .active,
          workStatus: .waiting,
          startedAt: Date().addingTimeInterval(-720),
          totalTokens: 2_100,
          totalCostUSD: 0.80,
          attentionReason: .awaitingQuestion,
          pendingQuestion: "Should I use the new type scale?"
        ),
        Session(
          id: "3",
          projectPath: "/Users/dev/claude-dashboard",
          projectName: "claude-dashboard",
          branch: "feat/auth",
          model: "claude-opus-4-5-20251101",
          summary: "Auth feature",
          status: .active,
          workStatus: .working,
          startedAt: Date().addingTimeInterval(-1_200),
          totalTokens: 4_100,
          totalCostUSD: 1.20
        ),
        Session(
          id: "4",
          projectPath: "/Users/dev/vizzly",
          projectName: "vizzly",
          branch: "feat/auth",
          model: "gpt-5.3",
          summary: "Implementing OAuth",
          status: .active,
          workStatus: .working,
          startedAt: Date().addingTimeInterval(-2_460),
          totalTokens: 12_500,
          totalCostUSD: 3.00,
          provider: .codex
        ),
      ],
      selectedIndex: 0,
      filter: $filter,
      sort: $sort,
      providerFilter: $providerFilter,
      projectGroupOrder: $projectGroupOrder,
      useCustomProjectOrder: $useCustomProjectOrder,
      hiddenProjectGroups: $hiddenProjectGroups
    )
    .padding(24)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 900, height: 600)
  .environment(ServerAppState())
  .environment(AppRouter())
  .environment(ServerRuntimeRegistry.shared)
}
