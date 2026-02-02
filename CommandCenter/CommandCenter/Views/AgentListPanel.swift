//
//  AgentListPanel.swift
//  OrbitDock
//
//  Left slide-in panel showing all agents grouped by status
//

import SwiftUI

struct AgentListPanel: View {
  @Environment(DatabaseManager.self) private var database
  let sessions: [Session]
  let selectedSessionId: String?
  let onSelectSession: (String) -> Void
  let onClose: () -> Void

  @State private var searchText = ""
  @State private var renamingSession: Session?
  @State private var renameText = ""

  /// Grouped sessions
  private var needsAttentionSessions: [Session] {
    sessions.filter(\.needsAttention)
  }

  private var workingSessions: [Session] {
    sessions.filter { $0.isActive && $0.workStatus == .working }
  }

  private var recentSessions: [Session] {
    sessions.filter { !$0.isActive }
      .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
      .prefix(10)
      .map { $0 }
  }

  private var filteredSessions: [Session] {
    guard !searchText.isEmpty else { return sessions }
    return sessions.filter {
      $0.displayName.localizedCaseInsensitiveContains(searchText) ||
        $0.projectPath.localizedCaseInsensitiveContains(searchText) ||
        ($0.branch ?? "").localizedCaseInsensitiveContains(searchText) ||
        ($0.summary ?? "").localizedCaseInsensitiveContains(searchText) ||
        ($0.customName ?? "").localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      panelHeader

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Search
      searchBar
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      // Content
      ScrollView {
        LazyVStack(spacing: 0) {
          if searchText.isEmpty {
            // Grouped view: Working → Needs Attention → Recent
            if !workingSessions.isEmpty {
              sectionView(
                title: "WORKING",
                sessions: workingSessions,
                color: .statusWorking,
                icon: "bolt.fill"
              )
            }

            if !needsAttentionSessions.isEmpty {
              sectionView(
                title: "NEEDS ATTENTION",
                sessions: needsAttentionSessions,
                color: .statusWaiting,
                icon: "exclamationmark.circle.fill"
              )
            }

            if !recentSessions.isEmpty {
              sectionView(
                title: "RECENT",
                sessions: Array(recentSessions),
                color: .secondary,
                icon: "clock"
              )
            }
          } else {
            // Search results
            ForEach(filteredSessions) { session in
              AgentRowCompact(
                session: session,
                isSelected: selectedSessionId == session.id,
                onSelect: { onSelectSession(session.id) },
                onRename: {
                  renameText = session.customName ?? ""
                  renamingSession = session
                }
              )
              .padding(.horizontal, 8)
            }
          }

          if sessions.isEmpty {
            emptyState
          }
        }
        .padding(.vertical, 4)
      }
      .scrollContentBackground(.hidden)
    }
    .frame(width: 280)
    .background(Color.panelBackground)
    .sheet(item: $renamingSession) { session in
      RenameSessionSheet(
        session: session,
        initialText: renameText,
        onSave: { newName in
          database.updateContextLabel(
            sessionId: session.id,
            label: newName.isEmpty ? nil : newName
          )
          renamingSession = nil
        },
        onCancel: {
          renamingSession = nil
        }
      )
    }
  }

  // MARK: - Panel Header

  private var panelHeader: some View {
    HStack {
      Text("Agents")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)

      Spacer()

      // Active count
      if !workingSessions.isEmpty || !needsAttentionSessions.isEmpty {
        HStack(spacing: 8) {
          if !workingSessions.isEmpty {
            HStack(spacing: 3) {
              Circle()
                .fill(Color.statusWorking)
                .frame(width: 6, height: 6)
              Text("\(workingSessions.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            }
          }

          if !needsAttentionSessions.isEmpty {
            HStack(spacing: 3) {
              Circle()
                .fill(Color.statusWaiting)
                .frame(width: 6, height: 6)
              Text("\(needsAttentionSessions.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .frame(width: 24, height: 24)
          .background(Color.surfaceHover, in: Circle())
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  // MARK: - Search Bar

  private var searchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.tertiary)

      TextField("Search agents...", text: $searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  // MARK: - Section View

  private func sectionView(title: String, sessions: [Session], color: Color, icon: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      // Section header - improved contrast
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(color)

        Text(title)
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(color.opacity(0.9))
          .tracking(0.5)

        Text("\(sessions.count)")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(color)
      }
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .padding(.bottom, 6)

      // Session rows
      ForEach(sessions) { session in
        AgentRowCompact(
          session: session,
          isSelected: selectedSessionId == session.id,
          onSelect: { onSelectSession(session.id) },
          onRename: {
            renameText = session.customName ?? ""
            renamingSession = session
          }
        )
        .padding(.horizontal, 8)
      }
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "terminal")
        .font(.system(size: 28))
        .foregroundStyle(.quaternary)

      VStack(spacing: 4) {
        Text("No Agents")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)

        Text("Start an AI session\nto see it here")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }
}

// MARK: - Preview

#Preview {
  HStack(spacing: 0) {
    AgentListPanel(
      sessions: [
        Session(
          id: "1",
          projectPath: "/Users/developer/Developer/vizzly-cli",
          projectName: "vizzly-cli",
          branch: "feat/auth",
          model: "claude-opus-4-5-20251101",
          contextLabel: "Auth refactor",
          transcriptPath: nil,
          status: .active,
          workStatus: .working,
          startedAt: Date(),
          endedAt: nil,
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ),
        Session(
          id: "2",
          projectPath: "/Users/developer/Developer/backchannel",
          projectName: "backchannel",
          branch: "main",
          model: "claude-sonnet-4-20250514",
          contextLabel: "API review",
          transcriptPath: nil,
          status: .active,
          workStatus: .waiting,
          startedAt: Date(),
          endedAt: nil,
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ),
        Session(
          id: "3",
          projectPath: "/Users/developer/Developer/docs",
          projectName: "docs",
          branch: "main",
          model: "claude-haiku-3-5-20241022",
          contextLabel: nil,
          transcriptPath: nil,
          status: .ended,
          workStatus: .unknown,
          startedAt: Date().addingTimeInterval(-7_200),
          endedAt: Date(),
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ),
      ],
      selectedSessionId: "1",
      onSelectSession: { _ in },
      onClose: {}
    )

    Rectangle()
      .fill(Color.backgroundPrimary)
  }
  .frame(width: 600, height: 500)
}

// MARK: - Rename Session Sheet

struct RenameSessionSheet: View {
  let session: Session
  let initialText: String
  let onSave: (String) -> Void
  let onCancel: () -> Void

  @State private var text: String = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Rename Session")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)
      .padding(.bottom, 12)

      Divider()

      // Content
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Project")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

          Text(session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
        }

        // Show AI-generated title if available
        if let summary = session.summary {
          VStack(alignment: .leading, spacing: 6) {
            Text("\(session.provider.displayName)'s Title")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)

            Text(summary.strippingXMLTags())
              .font(.system(size: 12))
              .foregroundStyle(.primary.opacity(0.8))
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(
                Color.backgroundTertiary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
              )
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Custom Name")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

          TextField("Override with your own name...", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .focused($isFocused)
        }

        Text("Leave empty to use the AI-generated title, or set a custom name.")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)

      Divider()

      // Actions
      HStack {
        if !initialText.isEmpty {
          Button("Clear Name") {
            onSave("")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }

        Spacer()

        Button("Cancel") {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)

        Button("Save") {
          onSave(text)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(text == initialText)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .frame(width: 340)
    .background(Color.panelBackground)
    .onAppear {
      text = initialText
      isFocused = true
    }
  }
}
