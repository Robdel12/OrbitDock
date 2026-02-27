//
//  CreateWorktreeSheet.swift
//  OrbitDock
//
//  Sheet for creating a new git worktree from the UI.
//  Follows the RenameSessionSheet layout pattern.
//

import SwiftUI

struct CreateWorktreeSheet: View {
  let repoPath: String
  let projectName: String
  let onCancel: () -> Void
  let onCreate: (String, String?) -> Void

  @State private var branchName = ""
  @State private var baseBranch = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("New Worktree")
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
          Text("Branch Name")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

          TextField("feat/my-feature", text: $branchName)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .focused($isFocused)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Base Branch")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

          TextField("main (optional)", text: $baseBranch)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }

        Text(
          "Creates a linked worktree at \(repoPath)/.orbitdock-worktrees/\(branchName.isEmpty ? "<branch>" : branchName)/"
        )
        .font(.system(size: 11))
        .foregroundStyle(Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)

      Divider()

      // Actions
      HStack {
        Spacer()

        Button("Cancel") {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)

        Button("Create") {
          let base = baseBranch.trimmingCharacters(in: .whitespaces)
          onCreate(branchName.trimmingCharacters(in: .whitespaces), base.isEmpty ? nil : base)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(branchName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .frame(width: 340)
    .background(Color.panelBackground)
    .onAppear {
      isFocused = true
    }
  }
}
