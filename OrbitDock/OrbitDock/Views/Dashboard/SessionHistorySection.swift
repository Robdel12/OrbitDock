//
//  SessionHistorySection.swift
//  OrbitDock
//
//  Chronological list of ended sessions for easy access to past work
//

import SwiftUI

struct SessionHistorySection: View {
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let sessions: [Session]

  @State private var isExpanded = false
  @State private var showAll = false
  @State private var groupByProject = true

  private let initialShowCount = 10

  /// Ended sessions sorted by end time (most recent first)
  private var endedSessions: [Session] {
    sessions
      .filter { !$0.isActive }
      .sorted { a, b in
        let aTime = a.endedAt ?? a.lastActivityAt ?? .distantPast
        let bTime = b.endedAt ?? b.lastActivityAt ?? .distantPast
        return aTime > bTime
      }
  }

  /// Sessions grouped by date period
  private var dateGroups: [DateGroup] {
    let calendar = Calendar.current
    let now = Date()

    var today: [Session] = []
    var yesterday: [Session] = []
    var thisWeek: [Session] = []
    var older: [Session] = []

    for session in endedSessions {
      let endDate = session.endedAt ?? session.lastActivityAt ?? .distantPast

      if calendar.isDateInToday(endDate) {
        today.append(session)
      } else if calendar.isDateInYesterday(endDate) {
        yesterday.append(session)
      } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                endDate > weekAgo
      {
        thisWeek.append(session)
      } else {
        older.append(session)
      }
    }

    var groups: [DateGroup] = []
    if !today.isEmpty {
      groups.append(DateGroup(title: "Today", sessions: today))
    }
    if !yesterday.isEmpty {
      groups.append(DateGroup(title: "Yesterday", sessions: yesterday))
    }
    if !thisWeek.isEmpty {
      groups.append(DateGroup(title: "This Week", sessions: thisWeek))
    }
    if !older.isEmpty {
      groups.append(DateGroup(title: "Older", sessions: older))
    }
    return groups
  }

  /// Sessions grouped by project for alternate view
  private var projectGroups: [SessionHistoryGroup] {
    let grouped = Dictionary(grouping: endedSessions) { session in
      let endpointScope = session.endpointId?.uuidString ?? "single-endpoint"
      return "\(endpointScope)::\(session.groupingPath)"
    }

    return grouped.compactMap { _, sessions in
      guard let first = sessions.first else { return nil }
      let path = first.groupingPath
      let endpointScope = first.endpointId?.uuidString ?? "single-endpoint"
      let projectName = sessions.first?.projectName
        ?? path.components(separatedBy: "/").last
        ?? "Unknown"

      return SessionHistoryGroup(
        groupKey: "\(endpointScope)::\(path)",
        projectPath: path,
        projectName: projectName,
        sessions: sessions
      )
    }
    .sorted { a, b in
      let aLatest = a.sessions.first?.endedAt ?? .distantPast
      let bLatest = b.sessions.first?.endedAt ?? .distantPast
      return aLatest > bLatest
    }
  }

  private var visibleSessions: [Session] {
    if showAll {
      return endedSessions
    }
    return Array(endedSessions.prefix(initialShowCount))
  }

  var body: some View {
    if !endedSessions.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        // Header
        sectionHeader

        // Content
        if isExpanded {
          VStack(spacing: 0) {
            if groupByProject {
              projectGroupedContent
            } else {
              chronologicalContent
            }
          }
          .padding(.top, Spacing.md)
        }
      }
    }
  }

  // MARK: - Section Header

  private var sectionHeader: some View {
    HStack(spacing: Spacing.md_) {
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))

      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.textSecondary)

      Text("Session History")
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textSecondary)

      Text("\(endedSessions.count)")
        .font(.system(size: TypeScale.meta, weight: .medium, design: .rounded))
        .foregroundStyle(Color.textTertiary)

      Spacer()

      // View toggle (only when expanded)
      if isExpanded {
        HStack(spacing: Spacing.xxs) {
          viewToggleButton(icon: "list.bullet", isActive: !groupByProject) {
            groupByProject = false
          }
          viewToggleButton(icon: "folder", isActive: groupByProject) {
            groupByProject = true
          }
        }
        .padding(Spacing.xxs)
        .background(Color.backgroundTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
      }
    }
    .padding(.vertical, Spacing.md_)
    .padding(.horizontal, Spacing.lg_)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(Color.backgroundTertiary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .onTapGesture {
      withAnimation(Motion.standard) {
        isExpanded.toggle()
      }
    }
  }

  private func viewToggleButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(isActive ? Color.accent : Color.textQuaternary)
        .frame(width: 24, height: 20)
        .background(
          isActive ? Color.accent.opacity(0.15) : Color.clear,
          in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Chronological Content

  private var chronologicalContent: some View {
    VStack(spacing: Spacing.lg) {
      ForEach(dateGroups) { group in
        DateGroupSection(
          group: group,
          showAll: showAll
        )
      }

      // Show more/less button
      if endedSessions.count > initialShowCount, !showAll {
        Button {
          withAnimation(Motion.standard) {
            showAll = true
          }
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "chevron.down")
              .font(.system(size: 9, weight: .semibold))
            Text("Show all \(endedSessions.count) sessions")
              .font(.system(size: TypeScale.meta, weight: .medium))
          }
          .foregroundStyle(Color.textTertiary)
          .padding(.vertical, Spacing.md_)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
      }
    }
  }

  // MARK: - Project Grouped Content

  private var projectGroupedContent: some View {
    VStack(spacing: Spacing.md) {
      ForEach(projectGroups) { group in
        ProjectHistoryGroup(
          group: group
        )
      }
    }
  }
}

// MARK: - Date Group

struct DateGroup: Identifiable {
  let title: String
  let sessions: [Session]

  var id: String {
    title
  }
}

// MARK: - Date Group Section

struct DateGroupSection: View {
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let group: DateGroup
  let showAll: Bool

  private let maxCollapsed = 4

  private var visibleSessions: [Session] {
    if showAll || group.sessions.count <= maxCollapsed {
      return group.sessions
    }
    return Array(group.sessions.prefix(maxCollapsed))
  }

  var body: some View {
    let referenceDate = Date()

    VStack(alignment: .leading, spacing: Spacing.sm_) {
      // Date header
      HStack(spacing: Spacing.sm) {
        Text(group.title.uppercased())
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textTertiary)
          .tracking(0.5)

        Text("\(group.sessions.count)")
          .font(.system(size: TypeScale.micro, weight: .semibold, design: .rounded))
          .foregroundStyle(Color.textQuaternary)

        Rectangle()
          .fill(Color.surfaceBorder.opacity(0.3))
          .frame(height: 1)
      }
      .padding(.horizontal, Spacing.xs)

      // Sessions
      VStack(spacing: Spacing.xxs) {
        ForEach(visibleSessions, id: \.scopedID) { session in
          HistorySessionRow(session: session, referenceDate: referenceDate) {
            withAnimation(Motion.standard) {
              router.dashboardScrollAnchorID = DashboardScrollIDs.session(session.scopedID)
              router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
            }
          }
        }

        // Truncation indicator
        if !showAll, group.sessions.count > maxCollapsed {
          Text("+ \(group.sessions.count - maxCollapsed) more")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
            .padding(.vertical, Spacing.xs)
            .padding(.horizontal, Spacing.md)
        }
      }
    }
  }
}

// MARK: - History Session Row

struct HistorySessionRow: View {
  let session: Session
  let referenceDate: Date
  let onSelect: () -> Void

  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  @State private var isHovering = false
  private static let timeAgoFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  private var timeAgo: String {
    guard let ended = session.endedAt else { return "" }
    return Self.timeAgoFormatter.localizedString(for: ended, relativeTo: referenceDate)
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: Spacing.md) {
        // Status dot
        Circle()
          .fill(Color.statusEnded)
          .frame(width: 6, height: 6)

        // Project + Session name
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(spacing: Spacing.sm_) {
            Text(session.displayName)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textSecondary)
              .lineLimit(1)

            if session.endpointName != nil {
              EndpointBadge(endpointName: session.endpointName)
            }

            if isForkedSession {
              ForkBadge()
            }
          }

          HStack(spacing: Spacing.sm_) {
            // Project
            HStack(spacing: Spacing.xs) {
              Image(systemName: "folder")
                .font(.system(size: 9))
              Text(session.projectName ?? "Unknown")
                .font(.system(size: TypeScale.micro, weight: .medium))
            }
            .foregroundStyle(Color.textTertiary)

            // Branch (if present)
            if let branch = session.branch, !branch.isEmpty {
              HStack(spacing: Spacing.gap) {
                Image(systemName: "arrow.triangle.branch")
                  .font(.system(size: 9))
                Text(branch)
                  .font(.system(size: TypeScale.micro, weight: .medium))
              }
              .foregroundStyle(Color.gitBranch.opacity(0.7))
            }
          }
        }

        Spacer()

        // Time ago
        Text(timeAgo)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)

        // Duration
        Text(session.formattedDuration)
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)

        // Model badge
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }
      .padding(.vertical, Spacing.sm)
      .padding(.horizontal, Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .fill(isHovering ? Color.surfaceHover : Color.clear)
      )
    }
    .id(DashboardScrollIDs.session(session.scopedID))
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu {
      Button {
        _ = Platform.services.revealInFileBrowser(session.projectPath)
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }

      Button {
        let command = "claude --resume \(session.id)"
        Platform.services.copyToClipboard(command)
      } label: {
        Label("Copy Resume Command", systemImage: "doc.on.doc")
      }
    }
  }

  private var isForkedSession: Bool {
    runtimeRegistry.isForkedSession(session, fallback: serverState)
  }
}

// MARK: - Session History Group

struct SessionHistoryGroup: Identifiable {
  let groupKey: String
  let projectPath: String
  let projectName: String
  let sessions: [Session]

  var id: String {
    groupKey
  }
}

// MARK: - Project History Group View

struct ProjectHistoryGroup: View {
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let group: SessionHistoryGroup

  @State private var isExpanded = true
  @State private var showAll = false

  private let maxCollapsed = 3

  private var visibleSessions: [Session] {
    if showAll || group.sessions.count <= maxCollapsed {
      return group.sessions
    }
    return Array(group.sessions.prefix(maxCollapsed))
  }

  var body: some View {
    let referenceDate = Date()

    VStack(alignment: .leading, spacing: 0) {
      // Project header
      Button {
        withAnimation(Motion.standard) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))

          Image(systemName: "folder.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          Text(group.projectName)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textSecondary)

          Text("\(group.sessions.count)")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .rounded))
            .foregroundStyle(Color.textQuaternary)

          Spacer()
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md_)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Sessions
      if isExpanded {
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
          if group.sessions.count > maxCollapsed, !showAll {
            Button {
              withAnimation(Motion.standard) {
                showAll = true
              }
            } label: {
              Text("Show \(group.sessions.count - maxCollapsed) more")
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

// MARK: - Compact History Row (for grouped view)

struct CompactHistoryRow: View {
  let session: Session
  let referenceDate: Date
  let onSelect: () -> Void

  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @State private var isHovering = false
  private static let timeAgoFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  private var timeAgo: String {
    guard let ended = session.endedAt else { return "" }
    return Self.timeAgoFormatter.localizedString(for: ended, relativeTo: referenceDate)
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: Spacing.md_) {
        Circle()
          .fill(Color.statusEnded)
          .frame(width: 5, height: 5)

        Text(session.displayName)
          .font(.system(size: TypeScale.meta, weight: .medium))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)

        if isForkedSession {
          ForkBadge()
        }

        Spacer()

        Text(timeAgo)
          .font(.system(size: TypeScale.mini, weight: .medium))
          .foregroundStyle(Color.textQuaternary)

        Text(session.formattedDuration)
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)

        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }
      .padding(.vertical, 5)
      .padding(.horizontal, Spacing.md_)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(isHovering ? Color.surfaceHover : Color.clear)
      )
    }
    .id(DashboardScrollIDs.session(session.scopedID))
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var isForkedSession: Bool {
    runtimeRegistry.isForkedSession(session, fallback: serverState)
  }
}

// MARK: - Preview

#Preview {
  ScrollView {
    VStack(spacing: Spacing.xl) {
      SessionHistorySection(
        sessions: [
          Session(
            id: "active-1",
            projectPath: "/Users/developer/Developer/vizzly",
            projectName: "vizzly",
            status: .active,
            workStatus: .working
          ),
          Session(
            id: "1",
            projectPath: "/Users/developer/Developer/vizzly",
            projectName: "vizzly",
            branch: "feat/auth",
            model: "claude-opus-4-5-20251101",
            summary: "OAuth implementation",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-3_600)
          ),
          Session(
            id: "2",
            projectPath: "/Users/developer/Developer/vizzly",
            projectName: "vizzly",
            model: "claude-sonnet-4-20250514",
            summary: "Bug fixes",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-7_200)
          ),
          Session(
            id: "3",
            projectPath: "/Users/developer/Developer/docs",
            projectName: "docs",
            model: "claude-haiku-3-5-20241022",
            summary: "README updates",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-10_800)
          ),
          Session(
            id: "4",
            projectPath: "/Users/developer/Developer/vizzly",
            projectName: "vizzly",
            model: "claude-sonnet-4-20250514",
            summary: "Tests",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-86_400)
          ),
          Session(
            id: "5",
            projectPath: "/Users/developer/Developer/cli",
            projectName: "cli",
            model: "claude-opus-4-5-20251101",
            summary: "CLI restructure",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-172_800)
          ),
        ]
      )
    }
    .padding(Spacing.xl)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 800, height: 600)
  .environment(AppRouter())
  .environment(ServerRuntimeRegistry.shared)
}
