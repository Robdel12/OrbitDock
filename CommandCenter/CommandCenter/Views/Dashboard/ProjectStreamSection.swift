//
//  ProjectStreamSection.swift
//  OrbitDock
//
//  Project-first flat session layout. Groups active sessions by project directory,
//  with branches shown inline per session row. Replaces lane-based triage grouping
//  with a developer-centric project-first mental model.
//

import SwiftUI

struct ProjectStreamSection: View {
  let sessions: [Session]
  let onSelectSession: (String) -> Void
  var selectedIndex: Int?
  @Binding var filter: ActiveSessionWorkbenchFilter
  @Binding var sort: ActiveSessionSort
  @Binding var providerFilter: ActiveSessionProviderFilter

  private var projectGroups: [ProjectGroup] {
    Self.makeProjectGroups(from: orderedSessions, sort: sort)
  }

  private var orderedSessions: [Session] {
    Self.keyboardNavigableSessions(from: sessions, filter: filter, sort: sort, providerFilter: providerFilter)
  }

  private var sessionIndexByID: [String: Int] {
    Dictionary(uniqueKeysWithValues: orderedSessions.enumerated().map { ($1.id, $0) })
  }

  private var allActiveSessions: [Session] {
    Self.sortedActiveSessions(from: sessions, sort: sort)
  }

  private var counts: ProjectStreamTriageCounts {
    ProjectStreamTriageCounts(sessions: allActiveSessions)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionHeader

      if projectGroups.isEmpty {
        emptyState
      } else {
        VStack(spacing: 0) {
          ForEach(projectGroups) { group in
            projectSection(group)
          }
        }
        .padding(.top, 4)
      }
    }
  }

  // MARK: - Public Ordering API

  static func keyboardNavigableSessions(
    from sessions: [Session],
    filter: ActiveSessionWorkbenchFilter,
    sort: ActiveSessionSort = .status,
    providerFilter: ActiveSessionProviderFilter = .all
  ) -> [Session] {
    let active = sortedActiveSessions(from: sessions, sort: sort)
    let providerFiltered = applyProviderFilter(active, filter: providerFilter)
    let filtered = applyWorkbenchFilter(providerFiltered, filter: filter)
    let groups = makeProjectGroups(from: filtered, sort: sort)
    return groups.flatMap(\.sessions)
  }

  // MARK: - Section Header

  private var sectionHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Line 1: Title
      HStack(spacing: 8) {
        Text("Active Agents")
          .font(.system(size: 16, weight: .bold))
          .foregroundStyle(.primary)

        Text("\(orderedSessions.count)")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.textTertiary)
      }

      // Line 2: Toolbar — sort + provider + state chips
      HStack(spacing: 0) {
        // Sort picker
        sortPicker

        thinSeparator

        // Provider filter
        providerToggle

        thinSeparator

        // State filter chips
        HStack(spacing: 4) {
          if directCount > 0 || filter == .direct {
            filterChip(
              target: .direct,
              icon: "chevron.left.forwardslash.chevron.right",
              count: directCount,
              color: .providerCodex
            )
          }

          if counts.attention > 0 || filter == .attention {
            filterChip(
              target: .attention,
              icon: "exclamationmark.circle.fill",
              count: counts.attention,
              color: .statusPermission
            )
          }

          if counts.running > 0 || filter == .running {
            filterChip(
              target: .running,
              icon: "bolt.fill",
              count: counts.running,
              color: .statusWorking
            )
          }

          if counts.ready > 0 || filter == .ready {
            filterChip(
              target: .ready,
              icon: "bubble.left.fill",
              count: counts.ready,
              color: .statusReply
            )
          }
        }

        Spacer()

        // Clear all filters
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
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 2)
  }

  // MARK: - Sort Picker

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

  // MARK: - Project Section

  private func projectSection(_ group: ProjectGroup) -> some View {
    let sharedBranch = group.sharedBranch

    return VStack(alignment: .leading, spacing: 0) {
      // Project divider rule
      Rectangle()
        .fill(Color.surfaceBorder.opacity(0.2))
        .frame(height: 1)
        .padding(.horizontal, 4)
        .padding(.top, 6)

      // Project header
      HStack(spacing: 8) {
        Text(group.projectName)
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(.primary)

        // Shared branch — shown here when all sessions are on the same branch
        if let branch = sharedBranch {
          Text(branch.count > 28 ? String(branch.prefix(26)) + "…" : branch)
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.gitBranch.opacity(0.7))
        }

        Text("\(group.sessions.count) \(group.sessions.count == 1 ? "agent" : "agents")")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(Color.textTertiary)

        Spacer()

        if group.totalTokens > 0 {
          Text(formatTokens(group.totalTokens))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 4)

      // Session rows
      VStack(spacing: 2) {
        ForEach(group.sessions) { session in
          let rowIndex = sessionIndexByID[session.id]
          let isSelected = rowIndex == selectedIndex

          FlatSessionRow(
            session: session,
            onSelect: { onSelectSession(session.id) },
            isSelected: isSelected,
            hideBranch: sharedBranch != nil
          )
          .flatSessionScrollID(rowIndex)
        }
      }
    }
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

  private static func sortedActiveSessions(from sessions: [Session], sort: ActiveSessionSort = .status) -> [Session] {
    sessions
      .filter(\.isActive)
      .sorted { lhs, rhs in
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

  static func makeProjectGroups(from sessions: [Session], sort: ActiveSessionSort = .status) -> [ProjectGroup] {
    // Merge subdirectory paths into their parent project.
    // e.g., sessions in /foo/bar and /foo/bar/sub both group under /foo/bar.
    // But don't merge into overly generic parent paths like ~/Developer.
    let allPaths = Set(sessions.map(\.projectPath))
    let canonicalPath: (String) -> String = { path in
      // If this path is a subdirectory of another session's path, merge up
      // Only merge into candidates that look like actual project dirs (4+ components)
      // e.g., /Users/name/Developer/project — not /Users/name/Developer
      for candidate in allPaths where candidate != path {
        let candidateComponents = candidate.components(separatedBy: "/").filter { !$0.isEmpty }
        if path.hasPrefix(candidate + "/") && candidateComponents.count >= 4 {
          return candidate
        }
      }
      return path
    }

    let grouped = Dictionary(grouping: sessions) { canonicalPath($0.projectPath) }

    return grouped.map { path, projectSessions in
      let sorted = projectSessions.sorted { lhs, rhs in
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

      let projectName = path.components(separatedBy: "/").last ?? "Unknown"

      return ProjectGroup(
        projectPath: path,
        projectName: projectName,
        sessions: sorted,
        totalCost: sorted.reduce(0) { $0 + $1.totalCostUSD },
        totalTokens: sorted.reduce(0) { $0 + $1.totalTokens },
        latestActivityAt: sorted.compactMap { sortDate($0) }.max() ?? .distantPast
      )
    }
    .sorted { lhs, rhs in
      switch sort {
        case .tokens: lhs.totalTokens > rhs.totalTokens
        case .cost: lhs.totalCost > rhs.totalCost
        default: lhs.latestActivityAt > rhs.latestActivityAt
      }
    }
  }

  private static func statusPriority(_ status: SessionDisplayStatus) -> Int {
    switch status {
      case .permission: 0
      case .question: 1
      case .working: 2
      case .reply: 3
      case .ended: 4
    }
  }

  private static func sortDate(_ session: Session) -> Date {
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
  let projectPath: String
  let projectName: String
  let sessions: [Session]
  let totalCost: Double
  let totalTokens: Int
  let latestActivityAt: Date

  var id: String {
    projectPath
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

// MARK: - Preview

#Preview {
  @Previewable @State var filter: ActiveSessionWorkbenchFilter = .all
  @Previewable @State var sort: ActiveSessionSort = .status
  @Previewable @State var providerFilter: ActiveSessionProviderFilter = .all

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
      onSelectSession: { _ in },
      selectedIndex: 0,
      filter: $filter,
      sort: $sort,
      providerFilter: $providerFilter
    )
    .padding(24)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 900, height: 600)
}
