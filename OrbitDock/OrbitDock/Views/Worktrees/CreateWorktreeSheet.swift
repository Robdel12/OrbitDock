//
//  CreateWorktreeSheet.swift
//  OrbitDock
//
//  Sheet for creating a new git worktree from the UI.
//  Follows the RenameSessionSheet layout pattern.
//

import SwiftUI

struct CreateWorktreeSheet: View {
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  let repoPath: String
  let projectName: String
  let onCancel: () -> Void
  let onCreate: (String, String?) -> Void

  @State private var branchName = ""
  @State private var baseBranch = ""
  @FocusState private var isFocused: Bool

  private var trimmedBranchName: String {
    branchName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedBaseBranch: String {
    baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  #if os(iOS)
    private var isPhoneCompact: Bool {
      horizontalSizeClass == .compact
    }
  #endif

  var body: some View {
    Group {
      #if os(iOS)
        if isPhoneCompact {
          compactLayout
        } else {
          panelLayout
        }
      #else
        panelLayout
      #endif
    }
    .onAppear {
      isFocused = true
    }
  }

  private var panelLayout: some View {
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
      formFields
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
          submitCreate()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(trimmedBranchName.isEmpty)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .ifMacOS { view in
      view.frame(width: 340)
    }
    .background(Color.panelBackground)
  }

  private var formFields: some View {
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
          .submitLabel(.done)
          .onSubmit {
            guard !trimmedBranchName.isEmpty else { return }
            submitCreate()
          }
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
        "Creates a linked worktree at \(repoPath)/.orbitdock-worktrees/\(trimmedBranchName.isEmpty ? "<branch>" : trimmedBranchName)/"
      )
      .font(.system(size: 11))
      .foregroundStyle(Color.textTertiary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  #if os(iOS)
    private var compactLayout: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            compactProjectHeader
            formFields
          }
          .padding(.horizontal, Spacing.lg)
          .padding(.top, Spacing.md)
          .padding(.bottom, Spacing.xl)
        }
        .background(Color.backgroundSecondary)
        .navigationTitle("New Worktree")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              onCancel()
            }
          }

          ToolbarItem(placement: .confirmationAction) {
            Button("Create") {
              submitCreate()
            }
            .disabled(trimmedBranchName.isEmpty)
          }
        }
      }
      .presentationDetents([.height(420), .medium])
      .presentationDragIndicator(.visible)
    }

    private var compactProjectHeader: some View {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(projectName)
          .font(.system(size: TypeScale.subhead, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(1)

        Text(repoPath)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.md)
      .background(
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .fill(Color.backgroundTertiary)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
          .stroke(Color.surfaceBorder, lineWidth: 1)
      }
    }
  #endif

  private func submitCreate() {
    let base = trimmedBaseBranch
    onCreate(trimmedBranchName, base.isEmpty ? nil : base)
  }
}
