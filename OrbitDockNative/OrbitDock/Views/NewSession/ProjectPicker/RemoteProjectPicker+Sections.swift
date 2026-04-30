import SwiftUI

extension RemoteProjectPicker {
  var recentProjectsView: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
        Label("Recent projects", systemImage: "clock.arrow.circlepath")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)

        Text("from session history")
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)

        Spacer()
      }

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
          Text("Launch once from Browse or Manual and it will stick here")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textQuaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
      } else {
        ScrollView {
          LazyVStack(spacing: Spacing.xxs) {
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
    let isExpanded = isRecentGroupExpanded(group)

    return VStack(spacing: Spacing.xxs) {
      if let project = group.repoProject {
        repoProjectRow(
          project: project,
          repoPath: group.repoPath,
          worktreeCount: group.worktrees.count,
          totalSessionCount: group.totalSessionCount,
          isExpanded: isExpanded
        )
      } else {
        syntheticRepoRow(group, isExpanded: isExpanded)
      }

      if isExpanded {
        VStack(spacing: Spacing.xxs) {
          ForEach(group.worktrees) { worktree in
            worktreeProjectRow(worktree)
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.vertical, 1)
  }

  func repoProjectRow(
    project: ServerRecentProject,
    repoPath: String,
    worktreeCount: Int,
    totalSessionCount: UInt32,
    isExpanded: Bool
  ) -> some View {
    projectSelectionRow(
      iconName: "folder.fill",
      iconFont: .system(size: 14),
      title: URL(fileURLWithPath: project.path).lastPathComponent,
      detail: ProjectPickerPlanner.displayPath(project.path),
      accentBadge: worktreeCount > 0 ? ProjectPickerPlanner.worktreeCountLabel(worktreeCount) : nil,
      trailingText: ProjectPickerPlanner.sessionCountLabel(totalSessionCount),
      selectionPath: project.path,
      leadingPadding: Spacing.md,
      isWorktree: false,
      disclosureExpanded: worktreeCount > 0 ? isExpanded : nil,
      onToggleDisclosure: worktreeCount > 0
        ? {
          toggleRecentGroup(repoPath)
        } : nil,
      previewTitle: URL(fileURLWithPath: project.path).lastPathComponent,
      previewPath: project.path,
      onSelect: {
        selectedPath = project.path
        selectedPathIsGit = true
        Platform.services.playHaptic(.selection)
      }
    )
  }

  func syntheticRepoRow(_ group: GroupedRecentProject, isExpanded: Bool) -> some View {
    projectSelectionRow(
      iconName: "folder.fill",
      iconFont: .system(size: 14),
      title: URL(fileURLWithPath: group.repoPath).lastPathComponent,
      detail: ProjectPickerPlanner.displayPath(group.repoPath),
      accentBadge: ProjectPickerPlanner.worktreeCountLabel(group.worktrees.count),
      trailingText: ProjectPickerPlanner.sessionCountLabel(group.totalSessionCount),
      selectionPath: group.repoPath,
      leadingPadding: Spacing.md,
      isWorktree: false,
      disclosureExpanded: isExpanded,
      onToggleDisclosure: {
        toggleRecentGroup(group.repoPath)
      },
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
      accentBadge: "worktree",
      trailingText: ProjectPickerPlanner.sessionCountLabel(worktree.project.sessionCount),
      selectionPath: worktree.project.path,
      leadingPadding: Spacing.xl + Spacing.md,
      isWorktree: true,
      disclosureExpanded: nil,
      onToggleDisclosure: nil,
      previewTitle: worktree.branchPath,
      previewPath: worktree.project.path,
      onSelect: {
        selectedPath = worktree.project.path
        selectedPathIsGit = true
        syncExpandedRepoPaths(for: worktree.project.path)
        Platform.services.playHaptic(.selection)
      }
    )
  }

  private func projectSelectionRow(
    iconName: String,
    iconFont: Font,
    title: String,
    detail: String,
    accentBadge: String?,
    trailingText: String?,
    selectionPath: String,
    leadingPadding: CGFloat,
    isWorktree: Bool,
    disclosureExpanded: Bool?,
    onToggleDisclosure: (() -> Void)?,
    previewTitle: String,
    previewPath: String,
    onSelect: @escaping () -> Void
  ) -> some View {
    let isSelected = selectedPath == selectionPath

    return HStack(spacing: Spacing.sm) {
      Button(action: onSelect) {
        HStack(alignment: .center, spacing: Spacing.md) {
          Image(systemName: iconName)
            .font(iconFont)
            .foregroundStyle(Color.accent)
            .frame(width: isWorktree ? 18 : 20)

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
              .font(.system(size: isWorktree ? TypeScale.body : TypeScale.subhead, weight: isWorktree ? .medium : .semibold))
              .foregroundStyle(Color.textPrimary)

            Text(detail)
              .font(.system(size: isWorktree ? TypeScale.meta : TypeScale.caption, design: .monospaced))
              .foregroundStyle(isWorktree ? Color.textQuaternary : Color.textTertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          Spacer()

          HStack(spacing: Spacing.sm) {
            if let accentBadge {
              Text(accentBadge)
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, Spacing.sm_)
                .padding(.vertical, Spacing.xxs)
                .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
            }

            if let trailingText {
              Text(trailingText)
                .font(.system(size: TypeScale.caption, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
                .fixedSize(horizontal: true, vertical: false)
            }
          }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, Spacing.md)
        .padding(.vertical, isWorktree ? Spacing.sm_ : Spacing.md_)
        .frame(minHeight: isWorktree ? 44 : 50, alignment: .leading)
        .background(
          isSelected
            ? Color.accent.opacity(OpacityTier.light)
            : Color.backgroundSecondary.opacity(isWorktree ? OpacityTier.tint : OpacityTier.subtle),
          in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
      }
      .buttonStyle(.plain)

      if let disclosureExpanded, let onToggleDisclosure {
        Button {
          withAnimation(Motion.standard) {
            onToggleDisclosure()
          }
          Platform.services.playHaptic(.selection)
        } label: {
          Image(systemName: disclosureExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .frame(width: 36, height: 36)
            .background(Color.backgroundSecondary.opacity(OpacityTier.subtle), in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .contextMenu {
      Button("Show Full Path") {
        pathPreview = PathPreviewItem(title: previewTitle, path: previewPath)
      }
      Button("Copy Path") {
        Platform.services.copyToClipboard(previewPath)
      }
    }
  }

  private func isRecentGroupExpanded(_ group: GroupedRecentProject) -> Bool {
    expandedRepoPaths.contains(group.repoPath)
  }

  private func toggleRecentGroup(_ repoPath: String) {
    if expandedRepoPaths.contains(repoPath) {
      expandedRepoPaths.remove(repoPath)
    } else {
      expandedRepoPaths.insert(repoPath)
    }
  }

  func syncExpandedRepoPaths(for selectionPath: String) {
    expandedRepoPaths = ProjectPickerPlanner.syncedExpandedRepoPaths(
      currentExpandedRepoPaths: expandedRepoPaths,
      groupedProjects: groupedRecentProjects,
      selectionPath: selectionPath
    )
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
        .autocorrectionDisabled()
        .platformTextInputAutocapitalization(.never)
        .platformURLKeyboard()

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
