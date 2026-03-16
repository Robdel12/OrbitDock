import SwiftUI

extension RemoteProjectPicker {
  var recentProjectsView: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      if isLoadingRecent {
        HStack {
          Spacer()
          ProgressView()
            .controlSize(.small)
          Spacer()
        }
        .padding(.vertical, Spacing.xl)
      } else if recentProjects.isEmpty {
        VStack(spacing: Spacing.sm) {
          Image(systemName: "clock")
            .font(.system(size: 24))
            .foregroundStyle(Color.textQuaternary)
          Text("No recent projects")
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textTertiary)
          Text("Start a session to see projects here")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textQuaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
      } else {
        ScrollView {
          LazyVStack(spacing: Spacing.xs) {
            ForEach(groupedRecentProjects) { group in
              groupedRecentProjectSection(group)
            }
          }
        }
        .frame(minHeight: 140, maxHeight: 240)
      }
    }
  }

  func groupedRecentProjectSection(_ group: GroupedRecentProject) -> some View {
    VStack(spacing: Spacing.sm) {
      if let project = group.repoProject {
        repoProjectRow(
          project: project,
          worktreeCount: group.worktrees.count,
          totalSessionCount: group.totalSessionCount
        )
      } else {
        syntheticRepoRow(group)
      }

      ForEach(group.worktrees) { worktree in
        worktreeProjectRow(worktree)
      }
    }
    .padding(.vertical, 1)
  }

  func repoProjectRow(
    project: ServerRecentProject,
    worktreeCount: Int,
    totalSessionCount: UInt32
  ) -> some View {
    projectSelectionRow(
      iconName: "folder.fill",
      iconFont: .system(size: 14),
      title: URL(fileURLWithPath: project.path).lastPathComponent,
      detail: ProjectPickerPlanner.displayPath(project.path),
      badges: projectBadges(worktreeCount: worktreeCount, sessionCount: totalSessionCount),
      selectionPath: project.path,
      leadingPadding: Spacing.md,
      previewTitle: URL(fileURLWithPath: project.path).lastPathComponent,
      previewPath: project.path,
      onSelect: {
        selectedPath = project.path
        selectedPathIsGit = true
        Platform.services.playHaptic(.selection)
      }
    )
  }

  func syntheticRepoRow(_ group: GroupedRecentProject) -> some View {
    projectSelectionRow(
      iconName: "folder.fill",
      iconFont: .system(size: 14),
      title: URL(fileURLWithPath: group.repoPath).lastPathComponent,
      detail: ProjectPickerPlanner.displayPath(group.repoPath),
      badges: [
        "\(group.worktrees.count) worktree\(group.worktrees.count == 1 ? "" : "s")",
        ProjectPickerPlanner.sessionCountLabel(group.totalSessionCount),
      ],
      selectionPath: group.repoPath,
      leadingPadding: Spacing.md,
      previewTitle: URL(fileURLWithPath: group.repoPath).lastPathComponent,
      previewPath: group.repoPath,
      onSelect: {
        selectedPath = group.repoPath
        selectedPathIsGit = true
        Platform.services.playHaptic(.selection)
      }
    )
  }

  func worktreeProjectRow(_ worktree: ProjectPickerRecentWorktreeProject) -> some View {
    projectSelectionRow(
      iconName: "arrow.triangle.branch",
      iconFont: .system(size: 13, weight: .semibold),
      title: worktree.branchPath,
      detail: ProjectPickerPlanner.worktreeRelativePath(worktree),
      badges: ["worktree", ProjectPickerPlanner.sessionCountLabel(worktree.project.sessionCount)],
      selectionPath: worktree.project.path,
      leadingPadding: Spacing.xl + Spacing.md,
      previewTitle: worktree.branchPath,
      previewPath: worktree.project.path,
      onSelect: {
        selectedPath = worktree.project.path
        selectedPathIsGit = true
        Platform.services.playHaptic(.selection)
      }
    )
  }

  private func projectBadges(worktreeCount: Int, sessionCount: UInt32) -> [String] {
    var badges: [String] = []
    if worktreeCount > 0 {
      badges.append("\(worktreeCount) worktree\(worktreeCount == 1 ? "" : "s")")
    }
    badges.append(ProjectPickerPlanner.sessionCountLabel(sessionCount))
    return badges
  }

  private func projectSelectionRow(
    iconName: String,
    iconFont: Font,
    title: String,
    detail: String,
    badges: [String],
    selectionPath: String,
    leadingPadding: CGFloat,
    previewTitle: String,
    previewPath: String,
    onSelect: @escaping () -> Void
  ) -> some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: Spacing.md) {
        Image(systemName: iconName)
          .font(iconFont)
          .foregroundStyle(Color.accent)
          .frame(width: 20)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(title)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textPrimary)

          Text(detail)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(2)
            .truncationMode(.middle)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: Spacing.xs) {
          ForEach(Array(badges.enumerated()), id: \.offset) { index, badge in
            if index == badges.count - 1, badges.count > 1 {
              Text(badge)
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textQuaternary)
                .multilineTextAlignment(.trailing)
            } else {
              Text(badge)
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, Spacing.sm_)
                .padding(.vertical, Spacing.xxs)
                .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
            }
          }
        }
      }
      .padding(.leading, leadingPadding)
      .padding(.trailing, Spacing.md)
      .padding(.vertical, Spacing.md)
      .background(
        selectedPath == selectionPath
          ? Color.accent.opacity(OpacityTier.light)
          : Color.backgroundSecondary.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Show Full Path") {
        pathPreview = PathPreviewItem(title: previewTitle, path: previewPath)
      }
      Button("Copy Path") {
        Platform.services.copyToClipboard(previewPath)
      }
    }
  }

  var directoryBrowserView: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        if ProjectPickerPlanner.canNavigateBack(browseHistory) {
          Button {
            navigateBack()
            Platform.services.playHaptic(.selection)
          } label: {
            Image(systemName: "chevron.left")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.accent)
              .frame(width: 28, height: 28)
              .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md))
          }
          .buttonStyle(.plain)
        }

        Text(ProjectPickerPlanner.displayPath(currentBrowsePath))
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
          .truncationMode(.head)

        Spacer()

        if !currentBrowsePath.isEmpty {
          Button {
            selectedPath = currentBrowsePath
            selectedPathIsGit = false
            Platform.services.playHaptic(.action)
          } label: {
            Text("Use This")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.accent)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xs)
              .background(Color.accent.opacity(OpacityTier.light), in: RoundedRectangle(cornerRadius: Radius.sm))
          }
          .buttonStyle(.plain)
        }
      }

      if isLoadingDirectory {
        HStack {
          Spacer()
          ProgressView()
            .controlSize(.small)
          Spacer()
        }
        .padding(.vertical, Spacing.xl)
      } else {
        ScrollView {
          LazyVStack(spacing: Spacing.xs) {
            ForEach(directoryEntries.filter(\.isDir)) { entry in
              directoryEntryRow(entry)
            }
          }
        }
        .frame(minHeight: 160, maxHeight: 280)
      }
    }
  }

  private func directoryEntryRow(_ entry: ServerDirectoryEntry) -> some View {
    Button {
      let newPath = ProjectPickerPlanner.childPath(entryName: entry.name, currentBrowsePath: currentBrowsePath)

      if entry.isGit {
        selectedPath = newPath
        selectedPathIsGit = true
        Platform.services.playHaptic(.selection)
      } else {
        browseDirectory(newPath)
        Platform.services.playHaptic(.selection)
      }
    } label: {
      HStack(spacing: Spacing.md) {
        Image(systemName: entry.isGit ? "chevron.left.forwardslash.chevron.right" : "folder")
          .font(.system(size: 13))
          .foregroundStyle(entry.isGit ? Color.accent : Color.textTertiary)
          .frame(width: 20)

        Text(entry.name)
          .font(.system(size: TypeScale.body, weight: entry.isGit ? .semibold : .regular))
          .foregroundStyle(entry.isGit ? Color.textPrimary : Color.textSecondary)

        Spacer()

        if entry.isGit {
          Text("repo")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.accent)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())
        } else {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.md)
      .background(
        Color.backgroundSecondary.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  var manualInputView: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Enter the full path to your project directory")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)

      TextField("~/Developer/my-project", text: $manualPathText)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.body, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .padding(Spacing.md)
        .background(
          Color.backgroundSecondary.opacity(OpacityTier.subtle),
          in: RoundedRectangle(cornerRadius: Radius.md)
        )
      #if os(iOS)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
      #endif

      Button {
        let trimmed = manualPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedPath = trimmed
        selectedPathIsGit = false
        Platform.services.playHaptic(.action)
      } label: {
        Text("Use Path")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .frame(maxWidth: .infinity)
          .foregroundStyle(Color.backgroundPrimary)
          .padding(.vertical, Spacing.md)
          .background(Color.accent, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(manualPathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  func pathPreviewSheet(_ item: PathPreviewItem) -> some View {
    RemoteProjectPickerPathPreviewSheet(
      title: item.title,
      path: item.path,
      onDismiss: { pathPreview = nil },
      onCopy: { Platform.services.copyToClipboard(item.path) }
    )
  }
}
