//
//  ActiveSessionsSection.swift
//  OrbitDock
//
//  Flat list of all active sessions, sorted by start time (newest first)
//

import SwiftUI

struct ActiveSessionsSection: View {
  let sessions: [Session]
  let onSelectSession: (String) -> Void
  var selectedIndex: Int?

  /// All active sessions sorted by start time (newest first)
  private var activeSessions: [Session] {
    sessions
      .filter(\.isActive)
      .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
  }

  /// Count by status for header display (5 distinct states)
  private var statusCounts: (working: Int, permission: Int, question: Int, reply: Int) {
    var working = 0
    var permission = 0
    var question = 0
    var reply = 0

    for session in activeSessions {
      switch SessionDisplayStatus.from(session) {
        case .working: working += 1
        case .permission: permission += 1
        case .question: question += 1
        case .reply: reply += 1
        case .ended: break
      }
    }

    return (working, permission, question, reply)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Section header
      sectionHeader

      if activeSessions.isEmpty {
        emptyState
      } else {
        // Session rows
        VStack(spacing: 6) {
          ForEach(Array(activeSessions.enumerated()), id: \.element.id) { index, session in
            ActiveSessionRow(
              session: session,
              onSelect: { onSelectSession(session.id) },
              onFocusTerminal: nil,
              isSelected: selectedIndex == index
            )
            .id("active-session-\(index)")
          }
        }
        .padding(.top, 12)
      }
    }
  }

  // MARK: - Section Header

  private var sectionHeader: some View {
    HStack(spacing: 12) {
      // Title with count
      HStack(spacing: 8) {
        Image(systemName: "cpu")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.accent)

        Text("Active Sessions")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.primary)

        Text("\(activeSessions.count)")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.surfaceHover, in: Capsule())
      }

      Spacer()

      // Status summary chips (5 distinct states)
      HStack(spacing: 8) {
        let counts = statusCounts

        if counts.working > 0 {
          statusChip(count: counts.working, status: .working)
        }

        if counts.permission > 0 {
          statusChip(count: counts.permission, status: .permission)
        }

        if counts.question > 0 {
          statusChip(count: counts.question, status: .question)
        }

        if counts.reply > 0 {
          statusChip(count: counts.reply, status: .reply)
        }
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .background(Color.backgroundTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func statusChip(count: Int, status: SessionDisplayStatus) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(status.color)
        .frame(width: 6, height: 6)
      Text("\(count)")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(status.color)
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
          .foregroundStyle(.tertiary)
      }

      VStack(spacing: 4) {
        Text("No Active Sessions")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)

        Text("Start an AI coding session to see it here")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
  }
}

// MARK: - Preview

#Preview {
  ScrollView {
    VStack(spacing: 24) {
      // With sessions
      ActiveSessionsSection(
        sessions: [
          Session(
            id: "1",
            projectPath: "/Users/developer/Developer/vizzly-cli",
            projectName: "vizzly-cli",
            branch: "main",
            model: "claude-opus-4-5-20251101",
            summary: "Building the new CLI",
            status: .active,
            workStatus: .working,
            startedAt: Date().addingTimeInterval(-8_100),
            lastTool: "Edit"
          ),
          Session(
            id: "2",
            projectPath: "/Users/developer/Developer/vizzly-core",
            projectName: "vizzly-core",
            branch: "feature/auth",
            model: "claude-sonnet-4-20250514",
            summary: "Implementing OAuth",
            status: .active,
            workStatus: .permission,
            startedAt: Date().addingTimeInterval(-2_700),
            attentionReason: .awaitingPermission,
            pendingToolName: "Bash"
          ),
          Session(
            id: "3",
            projectPath: "/Users/developer/Developer/marketing",
            projectName: "marketing",
            model: "claude-sonnet-4-20250514",
            summary: "Landing page redesign",
            status: .active,
            workStatus: .waiting,
            startedAt: Date().addingTimeInterval(-1_500),
            attentionReason: .awaitingQuestion,
            pendingQuestion: "Which color palette?"
          ),
          Session(
            id: "4",
            projectPath: "/Users/developer/Developer/docs",
            projectName: "docs",
            model: "claude-haiku-3-5-20241022",
            summary: "Documentation updates",
            status: .active,
            workStatus: .waiting,
            startedAt: Date().addingTimeInterval(-720),
            attentionReason: .awaitingReply
          ),
        ],
        onSelectSession: { _ in }
      )

      Divider()

      // Empty state
      ActiveSessionsSection(
        sessions: [],
        onSelectSession: { _ in }
      )
    }
    .padding(24)
  }
  .background(Color.backgroundPrimary)
  .frame(width: 800, height: 600)
}
