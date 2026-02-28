//
//  SidebarWorktreeRow.swift
//  OrbitDock
//
//  Compact worktree row for the workspace sidebar — shows idle/orphaned
//  worktrees inline under their project group with context menu cleanup.
//

import SwiftUI

struct SidebarWorktreeRow: View {
  let worktree: ServerWorktreeSummary
  let onRemove: (_ force: Bool, _ deleteBranch: Bool) -> Void

  @State private var isHovering = false

  private var displayName: String {
    worktree.customName ?? worktree.branch
  }

  private var statusLabel: String? {
    switch worktree.status {
      case .active: nil
      case .orphaned: "Orphaned"
      case .stale: "Stale"
      case .removing: "Removing"
      case .removed: "Removed"
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(statusColor.opacity(0.8))

      Text(displayName)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)

      Spacer(minLength: 4)

      if let label = statusLabel {
        Text(label)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(statusColor.opacity(0.8))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isHovering ? Color.surfaceHover : .clear)
    )
    .onHover { isHovering = $0 }
    .contextMenu {
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
}
