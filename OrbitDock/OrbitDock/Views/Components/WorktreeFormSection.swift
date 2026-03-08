//
//  WorktreeFormSection.swift
//  OrbitDock
//
//  Reusable worktree configuration card for session creation sheets.
//

import SwiftUI

struct WorktreeFormSection: View {
  @Binding var useWorktree: Bool
  @Binding var worktreeBranch: String
  @Binding var worktreeBaseBranch: String
  @Binding var worktreeError: String?
  let selectedPath: String
  let selectedPathIsGit: Bool
  let onGitInit: () -> Void

  @State private var showGitInitConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Toggle row
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(useWorktree ? Color.accent : Color.textTertiary)

        Text("Use Worktree")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)

        Spacer()

        Toggle("", isOn: $useWorktree)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.sm)

      if useWorktree {
        Divider()
          .padding(.horizontal, Spacing.lg)

        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Branch Name")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.textSecondary)
            TextField("feat/my-feature", text: $worktreeBranch)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
              Text("Base Branch")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
              Text("optional")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
            }
            TextField("main", text: $worktreeBaseBranch)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.body, design: .monospaced))
          }

          // Preview path
          let branchTrimmed = worktreeBranch.trimmingCharacters(in: .whitespaces)
          if !branchTrimmed.isEmpty {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 10))
                .foregroundStyle(Color.textQuaternary)
              Text("\(selectedPath)/.orbitdock-worktrees/\(branchTrimmed)/")
                .font(.system(size: TypeScale.micro, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }

          if let error = worktreeError {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.statusPermission)
              Text(error)
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.statusPermission)
            }
          }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
    .animation(Motion.bouncy, value: useWorktree)
    .onChange(of: useWorktree) { _, isOn in
      if isOn, !selectedPathIsGit {
        useWorktree = false
        showGitInitConfirmation = true
      }
      worktreeError = nil
    }
    .alert("Initialize Git Repository?", isPresented: $showGitInitConfirmation) {
      Button("Initialize") {
        onGitInit()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This directory is not a git repository. Initialize one to use worktrees?")
    }
  }
}
