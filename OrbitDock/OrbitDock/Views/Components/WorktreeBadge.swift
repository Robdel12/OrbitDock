//
//  WorktreeBadge.swift
//  OrbitDock
//
//  Compact pill indicating a session is running in a git worktree.
//  Follows the same visual pattern as ForkBadge and EndpointBadge.
//

import SwiftUI

struct WorktreeBadge: View {
  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 8, weight: .bold))
      Text("worktree")
        .font(.system(size: 9, weight: .medium))
    }
    .foregroundStyle(Color.gitBranch.opacity(0.8))
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(Color.gitBranch.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
  }
}

#Preview {
  HStack(spacing: 8) {
    WorktreeBadge()
    ForkBadge()
  }
  .padding()
  .background(Color.backgroundPrimary)
}
