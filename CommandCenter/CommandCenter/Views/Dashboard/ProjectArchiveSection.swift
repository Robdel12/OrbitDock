//
//  ProjectArchiveSection.swift
//  OrbitDock
//
//  Collapsible archive of ended sessions grouped by project
//

import SwiftUI

struct ProjectArchiveSection: View {
  let sessions: [Session]
  let onSelectSession: (String) -> Void

  @State private var isExpanded = false

  /// Only ended sessions, grouped by project
  private var projectGroups: [ProjectArchiveGroup] {
    let ended = sessions.filter { !$0.isActive }
    let grouped = Dictionary(grouping: ended) { $0.projectPath }

    return grouped.map { path, sessions in
      let projectName = sessions.first?.projectName
        ?? path.components(separatedBy: "/").last
        ?? "Unknown"

      // Sort by end time (most recent first)
      let sorted = sessions.sorted { a, b in
        let aTime = a.endedAt ?? a.lastActivityAt ?? .distantPast
        let bTime = b.endedAt ?? b.lastActivityAt ?? .distantPast
        return aTime > bTime
      }

      return ProjectArchiveGroup(
        projectPath: path,
        projectName: projectName,
        sessions: sorted
      )
    }
    .sorted { a, b in
      // Sort by most recent activity
      let aLatest = a.sessions.first?.endedAt ?? a.sessions.first?.lastActivityAt ?? .distantPast
      let bLatest = b.sessions.first?.endedAt ?? b.sessions.first?.lastActivityAt ?? .distantPast
      return aLatest > bLatest
    }
  }

  private var totalEndedCount: Int {
    sessions.filter { !$0.isActive }.count
  }

  var body: some View {
    if totalEndedCount > 0 {
      VStack(alignment: .leading, spacing: 0) {
        // Collapsible header
        Button {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            isExpanded.toggle()
          }
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.tertiary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))

            Image(systemName: "archivebox")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.secondary)

            Text("Project Archive")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.secondary)

            Text("\(totalEndedCount)")
              .font(.system(size: 11, weight: .medium, design: .rounded))
              .foregroundStyle(.tertiary)

            Spacer()
          }
          .padding(.vertical, 10)
          .padding(.horizontal, 14)
          .background(Color.backgroundTertiary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)

        // Expanded content
        if isExpanded {
          VStack(spacing: 12) {
            ForEach(projectGroups) { group in
              ProjectArchiveGroupView(
                group: group,
                onSelectSession: onSelectSession
              )
            }
          }
          .padding(.top, 12)
          .padding(.leading, 8)
        }
      }
    }
  }
}

// MARK: - Project Archive Group Model

struct ProjectArchiveGroup: Identifiable {
  let projectPath: String
  let projectName: String
  let sessions: [Session]

  var id: String {
    projectPath
  }
}

// MARK: - Project Archive Group View

struct ProjectArchiveGroupView: View {
  let group: ProjectArchiveGroup
  let onSelectSession: (String) -> Void

  @State private var isExpanded = false
  @State private var showAll = false

  private let maxCollapsedSessions = 3

  private var visibleSessions: [Session] {
    if showAll || group.sessions.count <= maxCollapsedSessions {
      return group.sessions
    }
    return Array(group.sessions.prefix(maxCollapsedSessions))
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

          Image(systemName: "folder")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)

          Text(group.projectName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)

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

      // Sessions (if expanded)
      if isExpanded {
        VStack(spacing: 2) {
          ForEach(visibleSessions, id: \.id) { session in
            CompactSessionRow(session: session) {
              onSelectSession(session.id)
            }
          }

          // Show more button
          if group.sessions.count > maxCollapsedSessions, !showAll {
            Button {
              withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                showAll = true
              }
            } label: {
              Text("Show \(group.sessions.count - maxCollapsedSessions) more")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.leading, 16)
        .padding(.top, 4)
      }
    }
  }
}

// MARK: - Compact Session Row (for archive)

struct CompactSessionRow: View {
  let session: Session
  let onSelect: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        // Small status dot
        Circle()
          .fill(Color.statusEnded)
          .frame(width: 5, height: 5)

        // Session name
        Text(session.displayName)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.tertiary)
          .lineLimit(1)

        Spacer()

        // Duration
        Text(session.formattedDuration)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(.quaternary)

        // Model badge
        ModelBadgeMini(model: session.model, provider: session.provider)
      }
      .padding(.vertical, 5)
      .padding(.horizontal, 10)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
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

// MARK: - Preview

#Preview {
  ScrollView {
    VStack(spacing: 24) {
      ProjectArchiveSection(
        sessions: [
          // Some active (should be filtered out)
          Session(
            id: "active-1",
            projectPath: "/Users/rob/Developer/vizzly",
            projectName: "vizzly",
            status: .active,
            workStatus: .working
          ),
          // Ended sessions
          Session(
            id: "1",
            projectPath: "/Users/rob/Developer/vizzly",
            projectName: "vizzly",
            model: "claude-opus-4-5-20251101",
            summary: "OAuth implementation",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-3_600)
          ),
          Session(
            id: "2",
            projectPath: "/Users/rob/Developer/vizzly",
            projectName: "vizzly",
            model: "claude-sonnet-4-20250514",
            summary: "Bug fixes",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-7_200)
          ),
          Session(
            id: "3",
            projectPath: "/Users/rob/Developer/docs",
            projectName: "docs",
            model: "claude-haiku-3-5-20241022",
            summary: "README updates",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-10_800)
          ),
          Session(
            id: "4",
            projectPath: "/Users/rob/Developer/vizzly",
            projectName: "vizzly",
            model: "claude-sonnet-4-20250514",
            summary: "Tests",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-14_400)
          ),
          Session(
            id: "5",
            projectPath: "/Users/rob/Developer/vizzly",
            projectName: "vizzly",
            model: "claude-sonnet-4-20250514",
            summary: "Another session",
            status: .ended,
            workStatus: .unknown,
            endedAt: Date().addingTimeInterval(-18_000)
          ),
        ],
        onSelectSession: { _ in }
      )
    }
    .padding(24)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 700, height: 500)
}
