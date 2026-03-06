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
  @Binding var sessionOrderByGroup: [String: [String]]

  @Binding var isEditMode: Bool

  @State private var worktreeSheetGroup: WorktreeSheetIdentifier?
  @State private var draggingProjectGroupKey: String?
  @State private var draggingSessionID: String?
  @State private var collapsedProjectGroups: Set<String> = []

  private var filteredSessions: [Session] {
    Self.filteredActiveSessions(
      from: sessions,
      filter: filter,
      sort: sort,
      providerFilter: providerFilter
    )
  }

  private var projectGroups: [ProjectGroup] {
    Self.makeProjectGroups(
      from: filteredSessions,
      allSessions: sessions,
      sort: sort,
      preferredOrder: useCustomProjectOrder ? projectGroupOrder : [],
      hiddenGroupKeys: hiddenProjectGroups,
      sessionOrderByGroup: sessionOrderByGroup
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

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var isPhoneCompact: Bool {
    layoutMode.isPhoneCompact
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if projectGroups.isEmpty {
        emptyState
      } else {
        VStack(spacing: Spacing.md) {
          ForEach(projectGroups) { group in
            if isEditMode {
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
                    draggingGroupKey: $draggingProjectGroupKey
                  )
                )
            } else {
              projectSection(group)
            }
          }
        }
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
    hiddenProjectGroups: Set<String> = [],
    sessionOrderByGroup: [String: [String]] = [:]
  ) -> [Session] {
    let filtered = filteredActiveSessions(
      from: sessions,
      filter: filter,
      sort: sort,
      providerFilter: providerFilter
    )
    let groups = makeProjectGroups(
      from: filtered,
      allSessions: sessions,
      sort: sort,
      preferredOrder: useCustomProjectOrder ? projectGroupOrder : [],
      hiddenGroupKeys: hiddenProjectGroups,
      sessionOrderByGroup: sessionOrderByGroup
    )
    return groups.flatMap(\.sessions)
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
        .font(.system(size: TypeScale.caption, weight: .semibold))
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
    var keys = useCustomProjectOrder ? reorderableGroupKeys :
      mergedProjectOrder(withVisible: projectGroups.map(\.groupKey))
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
    withAnimation(Motion.standard) {
      draggingProjectGroupKey = group.groupKey
    }
    return NSItemProvider(object: group.groupKey as NSString)
  }

  private func projectDragPreview(for group: ProjectGroup) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: TypeScale.micro, weight: .bold))
        .foregroundStyle(Color.textQuaternary)

      Text(group.projectName)
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Text("\(group.sessions.count)")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, 7)
        .padding(.vertical, Spacing.xxs)
        .background(Color.surfaceHover.opacity(0.75), in: Capsule())
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, Spacing.sm)
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
    if isEditMode {
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
    let worktreeCount = group.sessions.filter(\.isWorktree).count
    let repoRoot = group.sessions.compactMap(\.repositoryRoot).first
    let isCollapsed = isProjectCollapsed(group)
    let isReorderCompacting = isEditMode
    let isHistoryOnly = group.sessions.isEmpty

    return VStack(alignment: .leading, spacing: 0) {
      // Project divider rule — skip for history-only projects
      if !isHistoryOnly {
        Rectangle()
          .fill(Color.surfaceBorder.opacity(0.2))
          .frame(height: 1)
          .padding(.horizontal, Spacing.xs)
          .padding(.top, isReorderCompacting ? Spacing.xs : Spacing.md_)
      }

      // Project header
      Group {
        if isPhoneCompact {
          VStack(alignment: .leading, spacing: Spacing.sm_) {
            HStack(spacing: Spacing.sm) {
              if isEditMode {
                Image(systemName: "line.3.horizontal")
                  .font(.system(size: TypeScale.micro, weight: .bold))
                  .foregroundStyle(Color.textQuaternary)
                  .frame(width: 12, height: 12)
              } else {
                Button {
                  toggleProjectCollapsed(group)
                } label: {
                  Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: TypeScale.mini, weight: .bold))
                    .foregroundStyle(Color.textQuaternary)
                    .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
              }

              Text(group.projectName)
                .font(.system(
                  size: isHistoryOnly ? TypeScale.caption : TypeScale.subhead,
                  weight: .bold
                ))
                .foregroundStyle(isHistoryOnly ? Color.textSecondary : .primary)

              // Shared branch — shown here when all sessions are on the same branch
              if !isReorderCompacting, let branch = sharedBranch {
                Text(branch.count > 22 ? String(branch.prefix(20)) + "…" : branch)
                  .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                  .foregroundStyle(Color.gitBranch.opacity(0.7))
                  .lineLimit(1)
              }

              Text("\(group.sessions.count) \(group.sessions.count == 1 ? "agent" : "agents")")
                .font(.system(size: TypeScale.micro, weight: .medium, design: .rounded))
                .foregroundStyle(Color.textQuaternary)

              Spacer()

              if isEditMode {
                Button { hideProject(group) } label: {
                  Image(systemName: "eye.slash")
                    .font(.system(size: TypeScale.meta, weight: .medium))
                    .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
              } else {
                projectActionsMenu(group)
              }
            }

          }
        } else {
          HStack(spacing: Spacing.sm) {
            if isEditMode {
              Image(systemName: "line.3.horizontal")
                .font(.system(size: TypeScale.micro, weight: .bold))
                .foregroundStyle(Color.textQuaternary)
                .frame(width: 12, height: 12)
            } else {
              Button {
                toggleProjectCollapsed(group)
              } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                  .font(.system(size: TypeScale.mini, weight: .bold))
                  .foregroundStyle(Color.textQuaternary)
                  .frame(width: 12, height: 12)
              }
              .buttonStyle(.plain)
            }

            Text(group.projectName)
              .font(.system(
                size: isHistoryOnly ? TypeScale.caption : TypeScale.subhead,
                weight: .bold
              ))
              .foregroundStyle(isHistoryOnly ? Color.textSecondary : .primary)

            // Shared branch — shown here when all sessions are on the same branch
            if !isReorderCompacting, let branch = sharedBranch {
              Text(branch.count > 28 ? String(branch.prefix(26)) + "…" : branch)
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.gitBranch.opacity(0.7))
            }

            Text("\(group.sessions.count) \(group.sessions.count == 1 ? "agent" : "agents")")
              .font(.system(size: TypeScale.micro, weight: .medium, design: .rounded))
              .foregroundStyle(Color.textQuaternary)

            if !isReorderCompacting, let repoRoot {
              worktreeButton(repoRoot: repoRoot, projectName: group.projectName, count: worktreeCount)
            }

            if isEditMode {
              Button { hideProject(group) } label: {
                Image(systemName: "eye.slash")
                  .font(.system(size: TypeScale.meta, weight: .medium))
                  .foregroundStyle(Color.textTertiary)
              }
              .buttonStyle(.plain)
              .help("Hide project")
            } else {
              projectActionsMenu(group)
            }

            Spacer()

            if !isReorderCompacting, group.totalTokens > 0 {
              Text(formatTokens(group.totalTokens))
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.textQuaternary)
            }
          }
        }
      }
      .padding(.horizontal, Spacing.md_)
      .padding(.top, isReorderCompacting ? Spacing.sm : Spacing.lg_)
      .padding(.bottom, isReorderCompacting ? Spacing.xxs : Spacing.xs)

      if !isCollapsed {
        // Worktree strip — only show when worktrees exist and project has active sessions
        if !isHistoryOnly, hasWorktrees(for: group.projectPath) {
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
        }

        // Session rows
        VStack(spacing: Spacing.xxs) {
          ForEach(group.sessions, id: \.scopedID) { session in
            let rowIndex = sessionIndexByID[session.scopedID]
            let isSelected = rowIndex == selectedIndex

            FlatSessionRow(
              session: session,
              onSelect: {
                withAnimation(Motion.standard) {
                  router.dashboardScrollAnchorID = DashboardScrollIDs.session(session.scopedID)
                  router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
                }
              },
              isSelected: isSelected,
              hideBranch: sharedBranch != nil,
              isAttentionPromoted: SessionDisplayStatus.from(session).needsAttention
            )
            .flatSessionScrollID(rowIndex, scopedID: session.scopedID)
            .onDrag {
              withAnimation(Motion.standard) {
                draggingSessionID = session.scopedID
              }
              return NSItemProvider(object: session.scopedID as NSString)
            }
            .onDrop(
              of: [UTType.text],
              delegate: SessionDropDelegate(
                destinationScopedID: session.scopedID,
                groupKey: group.groupKey,
                groupSessionIDs: group.sessions.map(\.scopedID),
                sessionOrderByGroup: $sessionOrderByGroup,
                draggingSessionID: $draggingSessionID
              )
            )
          }
        }

        // Inline history sub-section for ended sessions
        if !group.endedSessions.isEmpty {
          InlineProjectHistory(
            endedSessions: group.endedSessions,
            groupKey: group.groupKey
          )
          .padding(.top, Spacing.xs)
        }
      }
    }
  }

  private func worktreeButton(repoRoot: String, projectName: String, count: Int) -> some View {
    let color: Color = count > 0 ? .gitBranch : .textQuaternary
    return Button {
      worktreeSheetGroup = WorktreeSheetIdentifier(
        repoRoot: repoRoot,
        projectName: projectName
      )
    } label: {
      HStack(spacing: Spacing.gap) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 8, weight: .bold))
        if count > 0 {
          Text("\(count)")
            .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        }
      }
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.gap)
      .background(color.opacity(0.10), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  /// Whether a project has real worktrees (excludes removed entries and the root itself).
  private func hasWorktrees(for repoRoot: String) -> Bool {
    !serverState.worktrees(for: repoRoot).filter {
      $0.status != .removed && $0.worktreePath != repoRoot
    }.isEmpty
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: Spacing.md) {
      ZStack {
        Circle()
          .fill(Color.backgroundTertiary)
          .frame(width: 50, height: 50)

        Image(systemName: "cpu")
          .font(.system(size: 20, weight: .light))
          .foregroundStyle(Color.textTertiary)
      }

      VStack(spacing: Spacing.xs) {
        if filter != .all {
          Text("No \(filter.title) Sessions")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
          Text("Try a different filter or clear the current one.")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textTertiary)
        } else {
          Text("No Active Sessions")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textSecondary)

          Text("Start an AI coding session to see it here.")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textTertiary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.xxl)
  }

  // MARK: - Data Builders

  /// Public access for DashboardView to compute project groups with the same filter pipeline.
  static func filteredActiveSessions(
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
    allSessions: [Session]? = nil,
    sort: ActiveSessionSort = .status,
    preferredOrder: [String] = [],
    hiddenGroupKeys: Set<String> = [],
    sessionOrderByGroup: [String: [String]] = [:]
  ) -> [ProjectGroup] {
    struct GroupBucketKey: Hashable {
      let endpointScope: String
      let path: String

      var groupKey: String {
        "\(endpointScope)::\(path)"
      }
    }

    // Build canonical path resolver from all sessions (active + ended) so ended
    // sessions merge into the same project buckets as active ones.
    let allSessionsForPaths = allSessions ?? sessions
    let pathsByEndpointScope = Dictionary(
      grouping: allSessionsForPaths
    ) { $0.endpointId?.uuidString ?? "single-endpoint" }
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

      for candidate in parentCandidates {
        let candidateComponents = candidate.components(separatedBy: "/").filter { !$0.isEmpty }
        if candidateComponents.count >= 4 {
          return candidate
        }
      }
      return path
    }

    // Group active sessions by project
    let grouped = Dictionary(grouping: sessions) { session -> GroupBucketKey in
      let path = canonicalPath(session)
      let endpointScope = session.endpointId?.uuidString ?? "single-endpoint"
      return GroupBucketKey(endpointScope: endpointScope, path: path)
    }

    // Group ended sessions by project (using same canonical path resolver)
    let endedSessions = (allSessions ?? []).filter { !$0.isActive }
    let endedGrouped = Dictionary(grouping: endedSessions) { session -> GroupBucketKey in
      let path = canonicalPath(session)
      let endpointScope = session.endpointId?.uuidString ?? "single-endpoint"
      return GroupBucketKey(endpointScope: endpointScope, path: path)
    }

    // Collect all bucket keys (active + ended-only projects)
    let allBucketKeys = Set(grouped.keys).union(endedGrouped.keys)

    let projectGroups: [ProjectGroup] = allBucketKeys.compactMap { bucketKey -> ProjectGroup? in
      let activeSessions = grouped[bucketKey] ?? []
      let endedForGroup = endedGrouped[bucketKey] ?? []

      // Skip groups with no sessions at all
      guard !activeSessions.isEmpty || !endedForGroup.isEmpty else { return nil }

      var sortedActive = activeSessions.sorted { lhs, rhs in
        compareSessions(lhs: lhs, rhs: rhs, sort: sort)
      }

      // Apply saved session order within this group
      if let savedOrder = sessionOrderByGroup[bucketKey.groupKey], !savedOrder.isEmpty {
        sortedActive.sort { a, b in
          let idxA = savedOrder.firstIndex(of: a.scopedID) ?? Int.max
          let idxB = savedOrder.firstIndex(of: b.scopedID) ?? Int.max
          return idxA < idxB
        }
      }

      let sortedEnded = endedForGroup.sorted { a, b in
        let aTime = a.endedAt ?? a.lastActivityAt ?? .distantPast
        let bTime = b.endedAt ?? b.lastActivityAt ?? .distantPast
        return aTime > bTime
      }

      let first = activeSessions.first ?? endedForGroup.first
      let path = bucketKey.path
      let projectName = first?.projectName ?? path.components(separatedBy: "/").last ?? "Unknown"

      let allForGroup = activeSessions + endedForGroup
      return ProjectGroup(
        groupKey: bucketKey.groupKey,
        projectPath: path,
        projectName: projectName,
        endpointName: first?.endpointName,
        sessions: sortedActive,
        endedSessions: sortedEnded,
        totalCost: allForGroup.reduce(0) { $0 + $1.totalCostUSD },
        totalTokens: allForGroup.reduce(0) { $0 + $1.totalTokens },
        latestActivityAt: allForGroup.map { $0.lastActivityAt ?? $0.startedAt ?? .distantPast }.max() ?? .distantPast
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
      case .name:
        // Within a project group, sort by status priority so attention items float to top
        let lhsPriority = statusPriority(SessionDisplayStatus.from(lhs))
        let rhsPriority = statusPriority(SessionDisplayStatus.from(rhs))
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return sortDate(lhs) > sortDate(rhs)

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
      case .name:
        return compareProjectGroupTiebreakers(lhs: lhs, rhs: rhs)

      case .status:
        let lhsPriority = lhs.activeSessions.map { statusPriority(SessionDisplayStatus.from($0)) }.min() ?? Int.max
        let rhsPriority = rhs.activeSessions.map { statusPriority(SessionDisplayStatus.from($0)) }.min() ?? Int.max
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
  let endedSessions: [Session]
  let totalCost: Double
  let totalTokens: Int
  let latestActivityAt: Date

  var id: String {
    groupKey
  }

  /// Active (non-ended) sessions only
  var activeSessions: [Session] {
    sessions
  }

  /// When all active sessions share the same branch, return it for the header.
  /// Returns nil if branches differ or are missing.
  var sharedBranch: String? {
    let branches = Set(sessions.compactMap(\.branch).filter { !$0.isEmpty })
    guard branches.count == 1, let branch = branches.first else { return nil }
    return branch
  }
}

// MARK: - Scroll ID

extension View {
  @ViewBuilder
  func flatSessionScrollID(_ index: Int?, scopedID: String? = nil) -> some View {
    if let scopedID {
      self.id(DashboardScrollIDs.session(scopedID))
    } else if let index {
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
    withAnimation(Motion.standard) {
      draggingGroupKey = nil
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

private struct SessionDropDelegate: DropDelegate {
  let destinationScopedID: String
  let groupKey: String
  let groupSessionIDs: [String]
  @Binding var sessionOrderByGroup: [String: [String]]
  @Binding var draggingSessionID: String?

  func dropEntered(info _: DropInfo) {
    guard let draggingID = draggingSessionID,
          draggingID != destinationScopedID,
          groupSessionIDs.contains(draggingID)
    else { return }

    var currentOrder = sessionOrderByGroup[groupKey] ?? groupSessionIDs
    // Ensure all current session IDs are in the order array
    for id in groupSessionIDs where !currentOrder.contains(id) {
      currentOrder.append(id)
    }
    // Remove stale IDs
    currentOrder = currentOrder.filter { groupSessionIDs.contains($0) }

    guard let fromIndex = currentOrder.firstIndex(of: draggingID),
          let toIndex = currentOrder.firstIndex(of: destinationScopedID),
          fromIndex != toIndex
    else { return }

    let movedID = currentOrder.remove(at: fromIndex)
    currentOrder.insert(movedID, at: toIndex)
    sessionOrderByGroup[groupKey] = currentOrder
  }

  func dropUpdated(info _: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info _: DropInfo) -> Bool {
    withAnimation(Motion.standard) {
      draggingSessionID = nil
    }
    return true
  }
}

// MARK: - Inline Project History

/// Collapsible history sub-section within a project group, showing ended sessions.
struct InlineProjectHistory: View {
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let endedSessions: [Session]
  let groupKey: String

  @State private var isExpanded = false
  @State private var showAll = false

  private let maxCollapsed = 3

  private var visibleSessions: [Session] {
    if showAll || endedSessions.count <= maxCollapsed {
      return endedSessions
    }
    return Array(endedSessions.prefix(maxCollapsed))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // History toggle header
      Button {
        withAnimation(Motion.standard) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))

          Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          Text("History")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Text("\(endedSessions.count)")
            .font(.system(size: TypeScale.mini, weight: .medium, design: .rounded))
            .foregroundStyle(Color.textQuaternary)

          Spacer()
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md_)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Ended session rows
      if isExpanded {
        let referenceDate = Date()

        VStack(spacing: Spacing.xxs) {
          ForEach(visibleSessions, id: \.scopedID) { session in
            CompactHistoryRow(session: session, referenceDate: referenceDate) {
              withAnimation(Motion.standard) {
                router.dashboardScrollAnchorID = DashboardScrollIDs.session(session.scopedID)
                router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
              }
            }
          }

          // Show more
          if endedSessions.count > maxCollapsed, !showAll {
            Button {
              withAnimation(Motion.standard) {
                showAll = true
              }
            } label: {
              Text("Show \(endedSessions.count - maxCollapsed) more")
                .font(.system(size: TypeScale.micro, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .padding(.vertical, Spacing.sm_)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.leading, Spacing.section)
        .padding(.top, Spacing.xs)
      }
    }
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
  @Previewable @State var sessionOrderByGroup: [String: [String]] = [:]
  @Previewable @State var isEditMode = false

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
      hiddenProjectGroups: $hiddenProjectGroups,
      sessionOrderByGroup: $sessionOrderByGroup,
      isEditMode: $isEditMode
    )
    .padding(Spacing.xl)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 900, height: 600)
  .environment(ServerAppState())
  .environment(AppRouter())
  .environment(ServerRuntimeRegistry.shared)
}
