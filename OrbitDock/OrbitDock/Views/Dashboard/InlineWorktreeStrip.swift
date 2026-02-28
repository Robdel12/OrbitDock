//
//  InlineWorktreeStrip.swift
//  OrbitDock
//
//  Worktree overview strip between the project header and session rows
//  on the dashboard. Always visible — shows worktrees when they exist,
//  or a subtle empty state with create/discover actions when they don't.
//  Each worktree row expands to show its associated sessions.
//

import SwiftUI

struct InlineWorktreeStrip: View {
  @Environment(ServerAppState.self) private var serverState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(AppRouter.self) private var router
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let repoRoot: String
  let projectName: String
  let allSessions: [Session]
  let onCreateClaudeSession: (String) -> Void
  let onCreateCodexSession: (String) -> Void
  let onOpenManageSheet: () -> Void

  @State private var isExpanded = true
  @State private var expandedWorktrees: Set<String> = []
  @State private var worktreeToRemove: ServerWorktreeSummary?
  @State private var pendingForce = false
  @State private var pendingDeleteBranch = false

  /// Only real worktrees — excludes the main working directory and removed entries.
  private var worktrees: [ServerWorktreeSummary] {
    serverState.worktrees(for: repoRoot).filter {
      $0.status != .removed && $0.worktreePath != repoRoot
    }
  }

  private var isPhoneCompact: Bool {
    horizontalSizeClass == .compact
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if worktrees.isEmpty {
        emptyState
      } else {
        populatedStrip
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: CGFloat(Radius.md), style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.25))
    )
    .padding(.horizontal, 10)
    .padding(.top, 2)
    .animation(.spring(response: 0.25, dampingFraction: 0.9), value: isExpanded)
    .animation(.spring(response: 0.25, dampingFraction: 0.9), value: worktrees.count)
    .alert(
      alertTitle,
      isPresented: Binding(
        get: { worktreeToRemove != nil },
        set: { if !$0 { resetRemoveState() } }
      )
    ) {
      Button(pendingForce ? "Force Remove" : "Remove", role: .destructive) {
        if let wt = worktreeToRemove {
          serverState.connection.removeWorktree(
            worktreeId: wt.id,
            force: pendingForce,
            deleteBranch: pendingDeleteBranch
          )
        }
        resetRemoveState()
      }
      Button("Cancel", role: .cancel) {
        resetRemoveState()
      }
    } message: {
      if let wt = worktreeToRemove {
        Text(alertMessage(for: wt))
      }
    }
  }

  // MARK: - Session Matching

  /// Sessions associated with a worktree — by worktreeId or path prefix.
  /// Uses `allSessions` (from UnifiedSessionsStore) which have `endpointId` set,
  /// so `scopedID` resolves correctly for navigation.
  private func sessions(for wt: ServerWorktreeSummary) -> [Session] {
    allSessions.filter { session in
      if let wtId = session.worktreeId, wtId == wt.id {
        return true
      }
      return session.projectPath.hasPrefix(wt.worktreePath)
    }
    .sorted { lhs, rhs in
      if lhs.isActive != rhs.isActive { return lhs.isActive }
      let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
      let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
      return lhsDate > rhsDate
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color.textQuaternary)

      Text("No worktrees")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.textQuaternary)

      Spacer()

      Button {
        onOpenManageSheet()
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "plus")
            .font(.system(size: 8, weight: .bold))
          Text("New")
            .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color.accent.opacity(0.8))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.accent.opacity(0.08), in: Capsule())
      }
      .buttonStyle(.plain)

      Button {
        serverState.connection.discoverWorktrees(repoPath: repoRoot)
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 8, weight: .bold))
          Text("Discover")
            .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color.textTertiary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.surfaceHover, in: Capsule())
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Populated Strip

  private var populatedStrip: some View {
    VStack(alignment: .leading, spacing: 0) {
      stripHeader

      if isExpanded {
        VStack(spacing: 1) {
          ForEach(worktrees) { wt in
            worktreeSection(wt)
          }
        }
        .padding(.top, 3)
      }
    }
  }

  // MARK: - Strip Header

  private var stripHeader: some View {
    HStack(spacing: 5) {
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .frame(width: 8)

          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.gitBranch.opacity(0.7))

          Text("Worktrees")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textTertiary)

          Text("\(worktrees.count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color.gitBranch.opacity(0.6))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Spacer()

      Button {
        onOpenManageSheet()
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "plus")
            .font(.system(size: 8, weight: .bold))
          Text("New")
            .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color.accent.opacity(0.8))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.accent.opacity(0.08), in: Capsule())
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Worktree Section (row + expandable sessions)

  private func worktreeSection(_ wt: ServerWorktreeSummary) -> some View {
    let wtSessions = sessions(for: wt)
    let isRowExpanded = expandedWorktrees.contains(wt.id)

    return VStack(alignment: .leading, spacing: 0) {
      WorktreeStripRow(
        worktree: wt,
        repoRoot: repoRoot,
        sessionCount: wtSessions.count,
        isRowExpanded: isRowExpanded,
        isPhoneCompact: isPhoneCompact,
        onToggleExpand: {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            if expandedWorktrees.contains(wt.id) {
              expandedWorktrees.remove(wt.id)
            } else {
              expandedWorktrees.insert(wt.id)
            }
          }
        },
        onCreateClaudeSession: { onCreateClaudeSession(wt.worktreePath) },
        onCreateCodexSession: { onCreateCodexSession(wt.worktreePath) },
        onRemove: { force, deleteBranch in
          worktreeToRemove = wt
          pendingForce = force
          pendingDeleteBranch = deleteBranch
        },
        onRevealInFinder: {
          Platform.services.revealInFileBrowser(wt.worktreePath)
        },
        onCopyPath: {
          Platform.services.copyToClipboard(wt.worktreePath)
        }
      )

      // Expanded session list
      if isRowExpanded {
        if wtSessions.isEmpty {
          HStack(spacing: 5) {
            Text("No sessions yet")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }
          .padding(.leading, 20)
          .padding(.vertical, 4)
        } else {
          VStack(spacing: 1) {
            ForEach(wtSessions, id: \.scopedID) { session in
              WorktreeSessionRow(
                session: session,
                onSelect: {
                  withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
                  }
                }
              )
              .padding(.leading, 14)
            }
          }
          .padding(.top, 2)
          .padding(.bottom, 3)
        }
      }
    }
  }

  // MARK: - Alert Helpers

  private var alertTitle: String {
    if pendingForce {
      return "Force Remove Worktree?"
    } else if pendingDeleteBranch {
      return "Remove Worktree + Branch?"
    }
    return "Remove Worktree?"
  }

  private func alertMessage(for wt: ServerWorktreeSummary) -> String {
    let name = wt.customName ?? wt.branch
    if pendingForce {
      return "Force removing \"\(name)\" will delete the worktree at \(wt.worktreePath) even if it has uncommitted changes."
    } else if pendingDeleteBranch {
      return "This will remove the worktree at \(wt.worktreePath) and delete the \"\(wt.branch)\" branch."
    }
    return "This will remove the worktree at \(wt.worktreePath)."
  }

  private func resetRemoveState() {
    worktreeToRemove = nil
    pendingForce = false
    pendingDeleteBranch = false
  }
}

// MARK: - Worktree Strip Row

private struct WorktreeStripRow: View {
  let worktree: ServerWorktreeSummary
  let repoRoot: String
  let sessionCount: Int
  let isRowExpanded: Bool
  let isPhoneCompact: Bool
  let onToggleExpand: () -> Void
  let onCreateClaudeSession: () -> Void
  let onCreateCodexSession: () -> Void
  let onRemove: (_ force: Bool, _ deleteBranch: Bool) -> Void
  let onRevealInFinder: () -> Void
  let onCopyPath: () -> Void

  @State private var isHovering = false

  /// Relative path from repo root
  private var relativePath: String {
    if worktree.worktreePath.hasPrefix(repoRoot + "/") {
      return String(worktree.worktreePath.dropFirst(repoRoot.count + 1))
    }
    return worktree.worktreePath
  }

  private var displayName: String {
    worktree.customName ?? worktree.branch
  }

  private var statusLabel: String? {
    switch worktree.status {
      case .active: nil
      case .orphaned: "Orphaned"
      case .stale: "Stale"
      case .removing: "Removing"
      case .removed: nil
    }
  }

  private var statusColor: Color {
    switch worktree.status {
      case .active: Color.accent
      case .orphaned: Color.statusReply
      case .stale: Color.textQuaternary
      case .removing: Color.textQuaternary
      case .removed: Color.textQuaternary
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        // Expand chevron (clickable to toggle sessions)
        Button(action: onToggleExpand) {
          Image(systemName: isRowExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .frame(width: 10)
        }
        .buttonStyle(.plain)

        // Status dot
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)

        // Name/status are on their own lane so right-side controls cannot overlap
        Button(action: onToggleExpand) {
          HStack(spacing: 5) {
            Text(displayName)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.primary)
              .lineLimit(1)

            if let label = statusLabel {
              Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(statusColor.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(statusColor.opacity(0.1), in: Capsule())
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)

        Spacer(minLength: 4)

        sessionCountBadge

        if isPhoneCompact {
          compactMenu
        } else {
          launchMenu
          overflowMenu
        }
      }

      Text(relativePath)
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, 22)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: CGFloat(Radius.sm), style: .continuous)
        .fill(isHovering ? Color.surfaceHover : .clear)
    )
    .onHover { isHovering = $0 }
  }

  private var sessionCountBadge: some View {
    Text(sessionCount > 0 ? "\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")" : "idle")
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(sessionCount > 0 ? Color.textTertiary : Color.textQuaternary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color.surfaceHover.opacity(0.55), in: Capsule())
  }

  // MARK: - Menus

  private var launchMenu: some View {
    Menu {
      Button {
        onCreateClaudeSession()
      } label: {
        Label("New Claude Session", systemImage: "terminal")
      }

      Button {
        onCreateCodexSession()
      } label: {
        Label("New Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(Color.accent)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var overflowMenu: some View {
    Menu {
      Button {
        onRemove(false, false)
      } label: {
        Label("Remove Worktree", systemImage: "trash")
      }

      Button {
        onRemove(false, true)
      } label: {
        Label("Remove + Delete Branch", systemImage: "trash")
      }

      Divider()

      Button {
        onRemove(true, false)
      } label: {
        Label("Force Remove", systemImage: "trash.fill")
      }

      Divider()

      #if os(macOS)
        Button {
          onRevealInFinder()
        } label: {
          Label("Reveal in Finder", systemImage: "folder")
        }
      #endif

      Button {
        onCopyPath()
      } label: {
        Label("Copy Path", systemImage: "doc.on.doc")
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var compactMenu: some View {
    Menu {
      Section("Launch") {
        Button {
          onCreateClaudeSession()
        } label: {
          Label("New Claude Session", systemImage: "terminal")
        }

        Button {
          onCreateCodexSession()
        } label: {
          Label("New Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
        }
      }

      Divider()

      Button {
        onRemove(false, false)
      } label: {
        Label("Remove Worktree", systemImage: "trash")
      }

      Button {
        onRemove(true, false)
      } label: {
        Label("Force Remove", systemImage: "trash.fill")
      }

      Divider()

      Button {
        onCopyPath()
      } label: {
        Label("Copy Path", systemImage: "doc.on.doc")
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}

// MARK: - Compact Session Row (inside worktree)

private struct WorktreeSessionRow: View {
  let session: Session
  let onSelect: () -> Void

  @State private var isHovering = false

  private var displayStatus: SessionDisplayStatus {
    SessionDisplayStatus.from(session)
  }

  private var agentLabel: String {
    if let custom = session.customName, !custom.isEmpty {
      return custom.strippingXMLTags()
    }
    if let summary = session.summary, !summary.isEmpty {
      return summary.strippingXMLTags()
    }
    if let prompt = session.firstPrompt, !prompt.isEmpty {
      let cleaned = prompt
        .strippingXMLTags()
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
      if cleaned.count > 50 {
        return String(cleaned.prefix(48)) + "..."
      }
      return cleaned
    }
    return "Untitled session"
  }

  private var timeLabel: String? {
    guard let date = session.lastActivityAt ?? session.startedAt else { return nil }
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 6) {
        // Status dot
        Circle()
          .fill(displayStatus.color)
          .frame(width: 5, height: 5)

        // Session name
        Text(agentLabel)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(session.isActive ? Color.textPrimary : Color.textTertiary)
          .lineLimit(1)

        Spacer(minLength: 4)

        // Time ago
        if let time = timeLabel {
          Text(time)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(Color.textQuaternary)
        }

        // Status badge for active sessions
        if session.isActive {
          Text(displayStatus.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(displayStatus.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(displayStatus.color.opacity(0.1), in: Capsule())
        } else {
          Text("Ended")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: CGFloat(Radius.sm), style: .continuous)
          .fill(isHovering ? Color.surfaceHover : .clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}
