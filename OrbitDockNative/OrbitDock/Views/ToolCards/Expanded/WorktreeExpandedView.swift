//
//  WorktreeExpandedView.swift
//  OrbitDock
//
//  Worktree path and branch badge display for EnterWorktree tools.
//

import SwiftUI

struct WorktreeExpandedView: View {
  let content: ServerRowContent

  private var worktreeInfo: (path: String?, branch: String?) {
    guard let input = content.inputDisplay else { return (nil, nil) }
    // Try to parse structured input
    if let data = input.data(using: .utf8),
       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      return (
        path: dict["path"] as? String ?? dict["worktree_path"] as? String,
        branch: dict["branch"] as? String ?? dict["branch_name"] as? String
      )
    }
    // Fallback: treat entire input as path
    return (path: input, branch: nil)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      let info = worktreeInfo

      if let path = info.path, !path.isEmpty {
        fieldRow(label: "Path", value: path, icon: "folder")
      }

      if let branch = info.branch, !branch.isEmpty {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: IconScale.xs))
            .foregroundStyle(Color.gitBranch)
            .frame(width: 14)
          Text("Branch")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .frame(width: 44, alignment: .trailing)
          Image(systemName: "tuningfork")
            .font(.system(size: 8))
            .foregroundStyle(Color.gitBranch.opacity(0.5))
          Text(branch)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.gitBranch)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(Color.gitBranch.opacity(OpacityTier.subtle), in: Capsule())
        }
      }

      if let output = content.outputDisplay, !output.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Result")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text(output)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
      }
    }
  }

  private func fieldRow(label: String, value: String, icon: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: IconScale.xs))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 14)
      Text(label)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .frame(width: 44, alignment: .trailing)
      Text(value)
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    }
  }
}
