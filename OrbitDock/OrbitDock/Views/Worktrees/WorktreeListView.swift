//
//  WorktreeListView.swift
//  OrbitDock
//
//  Sheet view for managing worktrees associated with a project group.
//  Lists active, orphaned, and stale worktrees with session counts
//  and provides actions to launch new sessions in each worktree.
//

import SwiftUI

struct WorktreeListView: View {
  @Environment(ServerAppState.self) private var serverState
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  let repoRoot: String
  let projectName: String
  let onDismiss: () -> Void
  let onCreateClaudeSession: (String) -> Void
  let onCreateCodexSession: (String) -> Void

  @State private var showCreateSheet = false
  @State private var worktreeToRemove: ServerWorktreeSummary?
  @State private var forceRemove = false

  private var worktrees: [ServerWorktreeSummary] {
    serverState.worktrees(for: repoRoot)
      .filter { $0.status != .removed }
      .sorted { $0.createdAt > $1.createdAt }
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
      serverState.connection.listWorktrees(repoRoot: repoRoot)
    }
    .sheet(isPresented: $showCreateSheet) {
      CreateWorktreeSheet(
        repoPath: repoRoot,
        projectName: projectName,
        onCancel: { showCreateSheet = false },
        onCreate: { branchName, baseBranch in
          serverState.connection.createWorktree(
            repoPath: repoRoot,
            branchName: branchName,
            baseBranch: baseBranch
          )
          showCreateSheet = false
        }
      )
      #if os(iOS)
        .presentationDetents([.height(380), .medium])
        .presentationDragIndicator(.visible)
      #endif
    }
    .alert(
      "Remove Worktree?",
      isPresented: Binding(
        get: { worktreeToRemove != nil },
        set: { if !$0 { worktreeToRemove = nil; forceRemove = false } }
      )
    ) {
      Button("Remove", role: .destructive) {
        if let wt = worktreeToRemove {
          serverState.connection.removeWorktree(worktreeId: wt.id, force: forceRemove)
        }
        worktreeToRemove = nil
        forceRemove = false
      }
      Button("Cancel", role: .cancel) {
        worktreeToRemove = nil
        forceRemove = false
      }
    } message: {
      if let wt = worktreeToRemove {
        if forceRemove {
          Text(
            "Force removing \"\(wt.customName ?? wt.branch)\" will delete the worktree at \(wt.worktreePath) even if it has uncommitted changes."
          )
        } else {
          Text("This will remove the worktree at \(wt.worktreePath). Active sessions in this worktree may be affected.")
        }
      }
    }
  }

  private var panelLayout: some View {
    VStack(spacing: 0) {
      panelHeader
      Divider()
      panelContent
      Divider()
      panelActionBar
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .ifMacOS { view in
      view.frame(width: 420)
    }
    .background(Color.panelBackground)
  }

  private var panelHeader: some View {
    HStack {
      Text("Worktrees")
        .font(.system(size: 13, weight: .semibold))

      Text(projectName)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.textSecondary)

      Spacer()

      Button { onDismiss() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.textTertiary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 12)
  }

  @ViewBuilder
  private var panelContent: some View {
    if worktrees.isEmpty {
      panelEmptyState
    } else {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(worktrees) { wt in
            worktreeRow(wt)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
      }
      .frame(maxHeight: 360)
    }
  }

  private var panelEmptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 24))
        .foregroundStyle(Color.textQuaternary)

      Text("No worktrees found")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Text("Create a worktree or discover existing ones.")
        .font(.system(size: 11))
        .foregroundStyle(Color.textQuaternary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  private var panelActionBar: some View {
    HStack {
      Button {
        serverState.connection.discoverWorktrees(repoPath: repoRoot)
      } label: {
        Label("Discover", systemImage: "arrow.clockwise")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color.textSecondary)

      Spacer()

      Button {
        showCreateSheet = true
      } label: {
        Label("New Worktree", systemImage: "plus")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  #if os(iOS)
    private var compactLayout: some View {
      NavigationStack {
        VStack(spacing: 0) {
          compactProjectHeader

          if worktrees.isEmpty {
            compactEmptyState
          } else {
            ScrollView {
              VStack(spacing: Spacing.sm) {
                ForEach(worktrees) { wt in
                  compactWorktreeRow(wt)
                }
              }
              .padding(.horizontal, Spacing.lg)
              .padding(.top, Spacing.md)
              .padding(.bottom, Spacing.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          }
        }
        .background(Color.backgroundSecondary)
        .navigationTitle("Worktrees")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
              onDismiss()
            }
          }
        }
        .safeAreaInset(edge: .bottom) {
          compactActionBar
        }
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }

    private var compactProjectHeader: some View {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(projectName)
          .font(.system(size: TypeScale.subhead, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
          .lineLimit(1)

        Text(repoRoot)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.lg)
      .padding(.top, Spacing.sm)
      .padding(.bottom, Spacing.xs)
    }

    private var compactEmptyState: some View {
      VStack(spacing: Spacing.md) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 32))
          .foregroundStyle(Color.textQuaternary)

        Text("No worktrees found")
          .font(.system(size: TypeScale.subhead, weight: .semibold))
          .foregroundStyle(Color.textSecondary)

        Text("Create a worktree or discover existing ones.")
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textTertiary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, Spacing.xl)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactActionBar: some View {
      HStack(spacing: Spacing.sm) {
        Button {
          serverState.connection.discoverWorktrees(repoPath: repoRoot)
        } label: {
          Label("Discover", systemImage: "arrow.clockwise")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        Button {
          showCreateSheet = true
        } label: {
          Label("New Worktree", systemImage: "plus")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.top, Spacing.sm)
      .padding(.bottom, Spacing.sm)
      .background(Color.backgroundSecondary)
      .overlay(alignment: .top) {
        Divider()
          .overlay(Color.surfaceBorder)
      }
    }

    private func compactWorktreeRow(_ wt: ServerWorktreeSummary) -> some View {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.sm) {
          Circle()
            .fill(statusColor(wt.status))
            .frame(width: 9, height: 9)

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(wt.customName ?? wt.branch)
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
              .lineLimit(1)

            if wt.status != .active {
              Text(wt.status.rawValue.capitalized)
                .font(.system(size: TypeScale.caption, weight: .medium))
                .foregroundStyle(statusColor(wt.status).opacity(0.8))
            }
          }

          Spacer()

          if wt.activeSessionCount > 0 {
            Text("\(wt.activeSessionCount) \(wt.activeSessionCount == 1 ? "agent" : "agents")")
              .font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
              .foregroundStyle(Color.textSecondary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xs)
              .background(Color.surfaceHover, in: Capsule())
          }

          actionMenu(for: wt, iconSize: 14, frameSize: 30)
        }

        Text(wt.worktreePath)
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(2)
          .truncationMode(.middle)

        HStack(spacing: Spacing.sm) {
          Button {
            onCreateClaudeSession(wt.worktreePath)
          } label: {
            Label("New Claude", systemImage: "terminal")
              .font(.system(size: TypeScale.body, weight: .semibold))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)

          Button {
            onCreateCodexSession(wt.worktreePath)
          } label: {
            Label("New Codex", systemImage: "chevron.left.forwardslash.chevron.right")
              .font(.system(size: TypeScale.body, weight: .semibold))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.providerCodex)
        }
      }
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

  // MARK: - Row

  private func worktreeRow(_ wt: ServerWorktreeSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        // Status dot
        Circle()
          .fill(statusColor(wt.status))
          .frame(width: 7, height: 7)

        // Branch name
        VStack(alignment: .leading, spacing: 2) {
          Text(wt.customName ?? wt.branch)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)

          if wt.status != .active {
            Text(wt.status.rawValue.capitalized)
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(statusColor(wt.status).opacity(0.8))
          }
        }

        Spacer()

        // Session count
        if wt.activeSessionCount > 0 {
          Text("\(wt.activeSessionCount) \(wt.activeSessionCount == 1 ? "agent" : "agents")")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Color.textTertiary)
        }

        actionMenu(for: wt, iconSize: 10, frameSize: 20)
      }

      // Worktree path
      Text(wt.worktreePath)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, 15)

      // Session launch buttons
      HStack(spacing: 6) {
        Button {
          onCreateClaudeSession(wt.worktreePath)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "play.fill")
              .font(.system(size: 7, weight: .bold))
            Text("New Claude")
              .font(.system(size: 10, weight: .medium))
          }
          .foregroundStyle(Color.accent)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)

        Button {
          onCreateCodexSession(wt.worktreePath)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "play.fill")
              .font(.system(size: 7, weight: .bold))
            Text("New Codex")
              .font(.system(size: 10, weight: .medium))
          }
          .foregroundStyle(Color.providerCodex)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.providerCodex.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)

        Spacer()
      }
      .padding(.leading, 15)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color.surfaceHover.opacity(0.3), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func actionMenu(for wt: ServerWorktreeSummary, iconSize: CGFloat, frameSize: CGFloat) -> some View {
    Menu {
      Button {
        worktreeToRemove = wt
        forceRemove = false
      } label: {
        Label("Remove Worktree", systemImage: "trash")
      }
      Button {
        worktreeToRemove = wt
        forceRemove = true
      } label: {
        Label("Force Remove", systemImage: "trash.fill")
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: iconSize, weight: .bold))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: frameSize, height: frameSize)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Helpers

  private func statusColor(_ status: ServerWorktreeStatus) -> Color {
    switch status {
      case .active: Color.accent
      case .orphaned: Color.statusReply
      case .stale: Color.textQuaternary
      case .removing: Color.textQuaternary
      case .removed: Color.textQuaternary
    }
  }
}
