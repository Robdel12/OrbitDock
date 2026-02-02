//
//  SessionHistorySection.swift
//  OrbitDock
//
//  Chronological list of ended sessions for easy access to past work
//

import SwiftUI

struct SessionHistorySection: View {
  let sessions: [Session]
  let onSelectSession: (String) -> Void

  @State private var isExpanded = false
  @State private var showAll = false
  @State private var groupByProject = false

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
    let grouped = Dictionary(grouping: endedSessions) { $0.projectPath }

    return grouped.map { path, sessions in
      let projectName = sessions.first?.projectName
        ?? path.components(separatedBy: "/").last
        ?? "Unknown"

      return SessionHistoryGroup(
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
          .padding(.top, 12)
        }
      }
    }
  }

  // MARK: - Section Header

  private var sectionHeader: some View {
    HStack(spacing: 10) {
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))

      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)

      Text("Session History")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)

      Text("\(endedSessions.count)")
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.tertiary)

      Spacer()

      // View toggle (only when expanded)
      if isExpanded {
        HStack(spacing: 2) {
          viewToggleButton(icon: "list.bullet", isActive: !groupByProject) {
            groupByProject = false
          }
          viewToggleButton(icon: "folder", isActive: groupByProject) {
            groupByProject = true
          }
        }
        .padding(2)
        .background(Color.backgroundTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(Color.backgroundTertiary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onTapGesture {
      withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
        isExpanded.toggle()
      }
    }
  }

  private func viewToggleButton(icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(isActive ? Color.accent : Color.white.opacity(0.35))
        .frame(width: 24, height: 20)
        .background(
          isActive ? Color.accent.opacity(0.15) : Color.clear,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Chronological Content

  private var chronologicalContent: some View {
    VStack(spacing: 16) {
      ForEach(dateGroups) { group in
        DateGroupSection(
          group: group,
          onSelectSession: onSelectSession,
          showAll: showAll
        )
      }

      // Show more/less button
      if endedSessions.count > initialShowCount, !showAll {
        Button {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showAll = true
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.down")
              .font(.system(size: 9, weight: .semibold))
            Text("Show all \(endedSessions.count) sessions")
              .font(.system(size: 11, weight: .medium))
          }
          .foregroundStyle(.tertiary)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
      }
    }
  }

  // MARK: - Project Grouped Content

  private var projectGroupedContent: some View {
    VStack(spacing: 12) {
      ForEach(projectGroups) { group in
        ProjectHistoryGroup(
          group: group,
          onSelectSession: onSelectSession
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
  let group: DateGroup
  let onSelectSession: (String) -> Void
  let showAll: Bool

  private let maxCollapsed = 4

  private var visibleSessions: [Session] {
    if showAll || group.sessions.count <= maxCollapsed {
      return group.sessions
    }
    return Array(group.sessions.prefix(maxCollapsed))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Date header
      HStack(spacing: 8) {
        Text(group.title.uppercased())
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(.tertiary)
          .tracking(0.5)

        Text("\(group.sessions.count)")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(.quaternary)

        Rectangle()
          .fill(Color.surfaceBorder.opacity(0.3))
          .frame(height: 1)
      }
      .padding(.horizontal, 4)

      // Sessions
      VStack(spacing: 2) {
        ForEach(visibleSessions, id: \.id) { session in
          HistorySessionRow(session: session) {
            onSelectSession(session.id)
          }
        }

        // Truncation indicator
        if !showAll, group.sessions.count > maxCollapsed {
          Text("+ \(group.sessions.count - maxCollapsed) more")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.quaternary)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
        }
      }
    }
  }
}

// MARK: - History Session Row

struct HistorySessionRow: View {
  let session: Session
  let onSelect: () -> Void

  @State private var isHovering = false

  private var timeAgo: String {
    guard let ended = session.endedAt else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: ended, relativeTo: Date())
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Status dot
        Circle()
          .fill(Color.statusEnded)
          .frame(width: 6, height: 6)

        // Project + Session name
        VStack(alignment: .leading, spacing: 2) {
          Text(session.displayName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)

          HStack(spacing: 6) {
            // Project
            HStack(spacing: 4) {
              Image(systemName: "folder")
                .font(.system(size: 9))
              Text(session.projectName ?? "Unknown")
                .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.tertiary)

            // Branch (if present)
            if let branch = session.branch, !branch.isEmpty {
              HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                  .font(.system(size: 9))
                Text(branch)
                  .font(.system(size: 10, weight: .medium))
              }
              .foregroundStyle(Color.gitBranch.opacity(0.7))
            }
          }
        }

        Spacer()

        // Time ago
        Text(timeAgo)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.quaternary)

        // Duration
        Text(session.formattedDuration)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(.tertiary)

        // Model badge
        ModelBadgeMini(model: session.model, provider: session.provider)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isHovering ? Color.surfaceHover : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .contextMenu {
      Button {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }

      Button {
        let command = "claude --resume \(session.id)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
      } label: {
        Label("Copy Resume Command", systemImage: "doc.on.doc")
      }
    }
  }
}

// MARK: - Session History Group

struct SessionHistoryGroup: Identifiable {
  let projectPath: String
  let projectName: String
  let sessions: [Session]

  var id: String {
    projectPath
  }
}

// MARK: - Project History Group View

struct ProjectHistoryGroup: View {
  let group: SessionHistoryGroup
  let onSelectSession: (String) -> Void

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
    VStack(alignment: .leading, spacing: 0) {
      // Project header
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.quaternary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))

          Image(systemName: "folder.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)

          Text(group.projectName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)

          Text("\(group.sessions.count)")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.quaternary)

          Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Sessions
      if isExpanded {
        VStack(spacing: 2) {
          ForEach(visibleSessions, id: \.id) { session in
            CompactHistoryRow(session: session) {
              onSelectSession(session.id)
            }
          }

          // Show more
          if group.sessions.count > maxCollapsed, !showAll {
            Button {
              withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                showAll = true
              }
            } label: {
              Text("Show \(group.sessions.count - maxCollapsed) more")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.leading, 20)
        .padding(.top, 4)
      }
    }
  }
}

// MARK: - Compact History Row (for grouped view)

struct CompactHistoryRow: View {
  let session: Session
  let onSelect: () -> Void

  @State private var isHovering = false

  private var timeAgo: String {
    guard let ended = session.endedAt else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: ended, relativeTo: Date())
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        Circle()
          .fill(Color.statusEnded)
          .frame(width: 5, height: 5)

        Text(session.displayName)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.tertiary)
          .lineLimit(1)

        Spacer()

        Text(timeAgo)
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.quaternary)

        Text(session.formattedDuration)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(.quaternary)

        ModelBadgeMini(model: session.model, provider: session.provider)
      }
      .padding(.vertical, 5)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isHovering ? Color.surfaceHover : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

// MARK: - Preview

#Preview {
  ScrollView {
    VStack(spacing: 24) {
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
        ],
        onSelectSession: { _ in }
      )
    }
    .padding(24)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 800, height: 600)
}
