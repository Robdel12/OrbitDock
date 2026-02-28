//
//  SidebarProjectGroup.swift
//  OrbitDock
//
//  Collapsible project group containing session rows.
//

import SwiftUI

struct SidebarProjectGroup: View {
  let group: ProjectGroup
  let selectedSessionId: String?
  let onSelectSession: (String) -> Void
  var onRenameSession: ((Session) -> Void)?
  var worktrees: [ServerWorktreeSummary] = []
  var onRemoveWorktree: ((ServerWorktreeSummary, Bool, Bool) -> Void)? // (wt, force, deleteBranch)

  @State private var isExpanded = true
  @State private var worktreeToRemove: ServerWorktreeSummary?
  @State private var pendingForce = false
  @State private var pendingDeleteBranch = false

  private var activeSessionCount: Int {
    group.sessions.filter(\.isActive).count
  }

  /// Real worktrees with no active sessions — the idle/orphaned cleanup targets.
  /// Excludes the main working directory (worktreePath == projectPath) and removed entries.
  private var idleWorktrees: [ServerWorktreeSummary] {
    worktrees.filter {
      $0.activeSessionCount == 0
        && $0.status != .removed
        && $0.worktreePath != group.projectPath
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      // Group header
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .frame(width: 10)

          Text(group.projectName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)

          if activeSessionCount > 0 {
            Text("\(activeSessionCount)")
              .font(.system(size: 9, weight: .bold, design: .rounded))
              .foregroundStyle(Color.textTertiary)
          }

          // Branch count badge (visible even when collapsed)
          if !isExpanded, !idleWorktrees.isEmpty {
            HStack(spacing: 2) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 7, weight: .bold))
              Text("\(idleWorktrees.count)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Color.gitBranch.opacity(0.6))
          }

          Spacer()

          if let endpointName = group.endpointName {
            Text(endpointName)
              .font(.system(size: 9, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Session rows + worktree rows
      if isExpanded {
        ForEach(group.sessions, id: \.scopedID) { session in
          SidebarSessionRow(
            session: session,
            isSelected: selectedSessionId == session.scopedID,
            onSelect: { onSelectSession(session.scopedID) },
            onRename: {
              onRenameSession?(session)
            }
          )
          .padding(.leading, 16)
        }

        // Idle worktrees (no active sessions)
        if !idleWorktrees.isEmpty {
          if !group.sessions.isEmpty {
            Divider()
              .foregroundStyle(Color.panelBorder)
              .padding(.horizontal, 16)
              .padding(.vertical, 2)
          }

          ForEach(idleWorktrees) { wt in
            SidebarWorktreeRow(worktree: wt) { force, deleteBranch in
              worktreeToRemove = wt
              pendingForce = force
              pendingDeleteBranch = deleteBranch
            }
            .padding(.leading, 16)
          }
        }
      }
    }
    .alert(
      alertTitle,
      isPresented: Binding(
        get: { worktreeToRemove != nil },
        set: { if !$0 { resetRemoveState() } }
      )
    ) {
      Button(pendingForce ? "Force Remove" : "Remove", role: .destructive) {
        if let wt = worktreeToRemove {
          onRemoveWorktree?(wt, pendingForce, pendingDeleteBranch)
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

#Preview {
  VStack(spacing: 8) {
    SidebarProjectGroup(
      group: ProjectGroup(
        groupKey: "OrbitDock",
        projectPath: "/Users/dev/OrbitDock",
        projectName: "OrbitDock",
        endpointName: nil,
        sessions: [
          Session(
            id: "1",
            projectPath: "/Users/dev/OrbitDock",
            projectName: "OrbitDock",
            branch: "feat/sidebar",
            model: "claude-opus-4-5-20251101",
            contextLabel: "Sidebar Redesign",
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
            projectPath: "/Users/dev/OrbitDock",
            projectName: "OrbitDock",
            branch: "main",
            model: "claude-sonnet-4-20250514",
            contextLabel: "Fix Scroll Anchor",
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
        ],
        totalCost: 0,
        totalTokens: 0,
        latestActivityAt: Date()
      ),
      selectedSessionId: "1",
      onSelectSession: { _ in }
    )
  }
  .padding(8)
  .background(Color.panelBackground)
  .frame(width: 320)
}
