//
//  CompleteWorktreeSheet.swift
//  OrbitDock
//
//  Unified completion/archive workflow for worktrees.
//  "Complete" performs git cleanup; "Archive" is app-only.
//

import SwiftUI

enum WorktreeCleanupMode: String, CaseIterable, Identifiable {
  case complete
  case archive

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .complete: "Complete"
      case .archive: "Archive"
    }
  }

  var actionLabel: String {
    switch self {
      case .complete: "Complete Worktree"
      case .archive: "Archive Worktree"
    }
  }
}

struct WorktreeCleanupRequest {
  let force: Bool
  let deleteBranch: Bool
  let deleteRemoteBranch: Bool
  let archiveOnly: Bool
}

struct CompleteWorktreeSheet: View {
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  let worktree: ServerWorktreeSummary
  let onCancel: () -> Void
  let onConfirm: (WorktreeCleanupRequest) -> Void

  @State private var mode: WorktreeCleanupMode
  @State private var forceRemove = false
  @State private var deleteBranch = false
  @State private var deleteRemoteBranch = false

  init(
    worktree: ServerWorktreeSummary,
    initialMode: WorktreeCleanupMode = .complete,
    onCancel: @escaping () -> Void,
    onConfirm: @escaping (WorktreeCleanupRequest) -> Void
  ) {
    self.worktree = worktree
    self.onCancel = onCancel
    self.onConfirm = onConfirm
    _mode = State(initialValue: initialMode)
  }

  private var displayName: String {
    worktree.customName ?? worktree.branch
  }

  private var cleanupRequest: WorktreeCleanupRequest {
    if mode == .archive {
      return WorktreeCleanupRequest(
        force: false,
        deleteBranch: false,
        deleteRemoteBranch: false,
        archiveOnly: true
      )
    }

    return WorktreeCleanupRequest(
      force: forceRemove,
      deleteBranch: deleteBranch,
      deleteRemoteBranch: deleteRemoteBranch,
      archiveOnly: false
    )
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
    .onChange(of: deleteRemoteBranch) { _, newValue in
      if newValue {
        deleteBranch = true
      }
    }
  }

  private var panelLayout: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Complete or Archive")
          .font(.system(size: TypeScale.body, weight: .semibold))
        Spacer()
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.top, Spacing.lg)
      .padding(.bottom, Spacing.md)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          contextSection

          Picker("Action", selection: $mode) {
            ForEach(WorktreeCleanupMode.allCases) { option in
              Text(option.title).tag(option)
            }
          }
          .pickerStyle(.segmented)

          if mode == .complete {
            completeOptionsSection
          } else {
            archiveInfoSection
          }
        }
        .padding(Spacing.lg)
      }

      Divider()

      HStack {
        Spacer()

        Button("Cancel") {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)

        Button(mode.actionLabel) {
          Platform.services.playHaptic(mode == .archive ? .action : .warning)
          onConfirm(cleanupRequest)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .tint(mode == .archive ? Color.accent : Color.statusPermission)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .ifMacOS { view in
      view.frame(width: 420)
    }
    .background(Color.panelBackground)
  }

  private var contextSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      Text(displayName)
        .font(.system(size: TypeScale.body, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)

      Text(worktree.worktreePath)
        .font(.system(size: TypeScale.meta, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(2)
        .truncationMode(.middle)
    }
  }

  private var completeOptionsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md_) {
      Text("Complete removes this worktree directory from disk and can clean up branch references.")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Toggle("Delete local branch \"\(worktree.branch)\"", isOn: $deleteBranch)
        .disabled(deleteRemoteBranch)

      Toggle("Delete remote branch on origin", isOn: $deleteRemoteBranch)

      Toggle("Force remove if there are local changes", isOn: $forceRemove)

      Text("Use force only when you are sure local changes in this worktree are disposable.")
        .font(.system(size: TypeScale.micro))
        .foregroundStyle(Color.textQuaternary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(size: TypeScale.caption, weight: .medium))
    .foregroundStyle(Color.textPrimary)
  }

  private var archiveInfoSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Archive keeps Git state untouched and only hides this worktree in OrbitDock.")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      Label("Directory is kept on disk", systemImage: "folder")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textTertiary)

      Label("Local and remote branches are unchanged", systemImage: "arrow.triangle.branch")
        .font(.system(size: TypeScale.meta))
        .foregroundStyle(Color.textTertiary)
    }
  }

  #if os(iOS)
    private var compactLayout: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            contextSection
              .padding(Spacing.md)
              .background(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                  .fill(Color.backgroundTertiary)
              )
              .overlay {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                  .stroke(Color.surfaceBorder, lineWidth: 1)
              }

            Picker("Action", selection: $mode) {
              ForEach(WorktreeCleanupMode.allCases) { option in
                Text(option.title).tag(option)
              }
            }
            .pickerStyle(.segmented)

            if mode == .complete {
              completeOptionsSection
            } else {
              archiveInfoSection
            }
          }
          .padding(.horizontal, Spacing.lg)
          .padding(.top, Spacing.md)
          .padding(.bottom, Spacing.xl)
        }
        .background(Color.backgroundSecondary)
        .navigationTitle("Complete Worktree")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              onCancel()
            }
          }

          ToolbarItem(placement: .confirmationAction) {
            Button(mode == .archive ? "Archive" : "Complete") {
              Platform.services.playHaptic(mode == .archive ? .action : .warning)
              onConfirm(cleanupRequest)
            }
          }
        }
      }
      .presentationDetents([.height(480), .large])
      .presentationDragIndicator(.visible)
    }
  #endif
}
