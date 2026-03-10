//
//  RemoteProjectPicker.swift
//  OrbitDock
//
//  Remote project picker for iOS — browses server filesystem.
//  Shows recent projects, directory browser, and manual path input.
//

import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.orbitdock", category: "remote-project-picker")

struct RemoteProjectPicker: View {
  private struct PathPreviewItem: Identifiable {
    let title: String
    let path: String
    let id = UUID()
  }

  @Binding var selectedPath: String
  @Binding var selectedPathIsGit: Bool
  let endpointId: UUID?
  private let endpointSettings: ServerEndpointSettingsClient
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @State private var recentProjects: [ServerRecentProject] = []
  @State private var directoryEntries: [ServerDirectoryEntry] = []
  @State private var currentBrowsePath: String = ""
  @State private var isLoadingRecent = false
  @State private var isLoadingDirectory = false
  @State private var manualPathText: String = ""
  @State private var activeTab: PickerTab = .recent
  @State private var browseHistory: [String] = []
  @State private var recentProjectsRequestId = UUID()
  @State private var browseRequestId = UUID()
  @State private var pathPreview: PathPreviewItem?

  @MainActor
  init(
    selectedPath: Binding<String>,
    selectedPathIsGit: Binding<Bool> = .constant(true),
    endpointId: UUID? = nil,
    endpointSettings: ServerEndpointSettingsClient? = nil
  ) {
    _selectedPath = selectedPath
    _selectedPathIsGit = selectedPathIsGit
    self.endpointId = endpointId
    self.endpointSettings = endpointSettings ?? .live()
  }

  private enum PickerTab: String, CaseIterable {
    case recent = "Recent"
    case browse = "Browse"
    case manual = "Manual"
  }

  private var groupedRecentProjects: [GroupedRecentProject] {
    ProjectPickerPlanner.groupedRecentProjects(from: recentProjects)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      Text("Project Directory")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      if !selectedPath.isEmpty {
        selectedPathBanner
      }

      tabPicker

      tabContentCard
    }
    .onAppear {
      loadRecentProjects()
    }
    .onChange(of: endpointId) { _, _ in
      resetEndpointScopedState()
    }
    .sheet(item: $pathPreview) { item in
      pathPreviewSheet(item)
      #if os(iOS)
        .presentationDetents([.height(320), .medium])
        .presentationDragIndicator(.visible)
      #endif
    }
  }

  // MARK: - Selected Path Banner

  private var selectedPathBanner: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "folder.fill")
        .font(.system(size: 12))
        .foregroundStyle(Color.accent)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(URL(fileURLWithPath: selectedPath).lastPathComponent)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textPrimary)

        Text(ProjectPickerPlanner.displayPath(selectedPath))
          .font(.system(size: TypeScale.caption, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer()

      if !selectedPath.isEmpty {
        Button {
          Platform.services.copyToClipboard(selectedPath)
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 13))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
      }

      Button {
        selectedPath = ""
        selectedPathIsGit = true
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(Color.textQuaternary)
      }
      .buttonStyle(.plain)
    }
    .padding(Spacing.md)
    .background(Color.accent.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
  }

  // MARK: - Tab Picker

  private var tabPicker: some View {
    HStack(spacing: Spacing.xs) {
      ForEach(PickerTab.allCases, id: \.self) { tab in
        Button {
          withAnimation(Motion.hover) {
            activeTab = tab
          }
          Platform.services.playHaptic(.selection)
          if tab == .browse, directoryEntries.isEmpty {
            browseDirectory(nil)
          }
        } label: {
          Text(tab.rawValue)
            .font(.system(size: TypeScale.body, weight: activeTab == tab ? .semibold : .medium))
            .foregroundStyle(activeTab == tab ? Color.accent : Color.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm + 1)
            .background(
              activeTab == tab
                ? Color.accent.opacity(OpacityTier.light)
                : Color.clear,
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(Spacing.xs)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private var tabContentCard: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      switch activeTab {
        case .recent:
          recentProjectsView
        case .browse:
          directoryBrowserView
        case .manual:
          manualInputView
      }
    }
    .padding(Spacing.md)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  // MARK: - Recent Projects

  private var recentProjectsView: some View {
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

  private func groupedRecentProjectSection(_ group: GroupedRecentProject) -> some View {
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

  private func repoProjectRow(
    project: ServerRecentProject,
    worktreeCount: Int,
    totalSessionCount: UInt32
  ) -> some View {
    Button {
      selectedPath = project.path
      selectedPathIsGit = true
      Platform.services.playHaptic(.selection)
    } label: {
      HStack(alignment: .top, spacing: Spacing.md) {
        Image(systemName: "folder.fill")
          .font(.system(size: 14))
          .foregroundStyle(Color.accent)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(URL(fileURLWithPath: project.path).lastPathComponent)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textPrimary)

          Text(ProjectPickerPlanner.displayPath(project.path))
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(2)
            .truncationMode(.middle)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: Spacing.xs) {
          if worktreeCount > 0 {
            Text("\(worktreeCount) worktree\(worktreeCount == 1 ? "" : "s")")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.accent)
              .padding(.horizontal, Spacing.sm_)
              .padding(.vertical, Spacing.xxs)
              .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())
              .fixedSize(horizontal: true, vertical: false)
          }

          Text(ProjectPickerPlanner.sessionCountLabel(totalSessionCount))
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textQuaternary)
            .multilineTextAlignment(.trailing)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.md)
      .background(
        selectedPath == project.path
          ? Color.accent.opacity(OpacityTier.light)
          : Color.backgroundSecondary.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Show Full Path") {
        pathPreview = PathPreviewItem(
          title: URL(fileURLWithPath: project.path).lastPathComponent,
          path: project.path
        )
      }
      Button("Copy Path") {
        Platform.services.copyToClipboard(project.path)
      }
    }
  }

  private func syntheticRepoRow(_ group: GroupedRecentProject) -> some View {
    Button {
      selectedPath = group.repoPath
      selectedPathIsGit = true
      Platform.services.playHaptic(.selection)
    } label: {
      HStack(alignment: .top, spacing: Spacing.md) {
        Image(systemName: "folder.fill")
          .font(.system(size: 14))
          .foregroundStyle(Color.accent)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(URL(fileURLWithPath: group.repoPath).lastPathComponent)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textPrimary)

          Text(ProjectPickerPlanner.displayPath(group.repoPath))
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(2)
            .truncationMode(.middle)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: Spacing.xs) {
          Text("\(group.worktrees.count) worktree\(group.worktrees.count == 1 ? "" : "s")")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.accent)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)

          Text(ProjectPickerPlanner.sessionCountLabel(group.totalSessionCount))
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textQuaternary)
            .multilineTextAlignment(.trailing)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.md)
      .background(
        selectedPath == group.repoPath
          ? Color.accent.opacity(OpacityTier.light)
          : Color.backgroundSecondary.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Show Full Path") {
        pathPreview = PathPreviewItem(
          title: URL(fileURLWithPath: group.repoPath).lastPathComponent,
          path: group.repoPath
        )
      }
      Button("Copy Path") {
        Platform.services.copyToClipboard(group.repoPath)
      }
    }
  }

  private func worktreeProjectRow(_ worktree: ProjectPickerRecentWorktreeProject) -> some View {
    Button {
      selectedPath = worktree.project.path
      selectedPathIsGit = true
      Platform.services.playHaptic(.selection)
    } label: {
      HStack(alignment: .top, spacing: Spacing.md) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.accent)
          .frame(width: 20)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(worktree.branchPath)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textPrimary)

          Text(ProjectPickerPlanner.worktreeRelativePath(worktree))
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(2)
            .truncationMode(.middle)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: Spacing.xs) {
          Text("worktree")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.accent)
            .padding(.horizontal, Spacing.sm_)
            .padding(.vertical, Spacing.xxs)
            .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)

          Text(ProjectPickerPlanner.sessionCountLabel(worktree.project.sessionCount))
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textQuaternary)
            .multilineTextAlignment(.trailing)
        }
      }
      .padding(.leading, Spacing.xl + Spacing.md)
      .padding(.trailing, Spacing.md)
      .padding(.vertical, Spacing.md)
      .background(
        selectedPath == worktree.project.path
          ? Color.accent.opacity(OpacityTier.light)
          : Color.backgroundSecondary.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Show Full Path") {
        pathPreview = PathPreviewItem(
          title: worktree.branchPath,
          path: worktree.project.path
        )
      }
      Button("Copy Path") {
        Platform.services.copyToClipboard(worktree.project.path)
      }
    }
  }

  // MARK: - Directory Browser

  private var directoryBrowserView: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Breadcrumb / current path
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
        // Git repo — select it as the project path
        selectedPath = newPath
        selectedPathIsGit = true
        Platform.services.playHaptic(.selection)
      } else {
        // Regular dir — navigate into it
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

  // MARK: - Manual Input

  private var manualInputView: some View {
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
        selectedPathIsGit = false // Unknown — let the sheet handle verification
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

  // MARK: - Helpers

  private func pathPreviewSheet(_ item: PathPreviewItem) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Full Path")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      Text(item.title)
        .font(.system(size: TypeScale.title, weight: .semibold))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "folder")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
          Text("Tap and hold to select")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }

        ScrollView {
          Text(item.path)
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.vertical, Spacing.xxs)
        }
        .frame(maxHeight: 120)
      }
      .padding(Spacing.md)
      .background(
        Color.backgroundTertiary,
        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .stroke(Color.surfaceBorder, lineWidth: 1)
      )

      HStack(spacing: Spacing.sm) {
        Button {
          pathPreview = nil
        } label: {
          Text("Done")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        Button {
          Platform.services.copyToClipboard(item.path)
        } label: {
          Label("Copy Path", systemImage: "doc.on.doc")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)
      }
    }
    .padding(Spacing.xl)
    .background(Color.backgroundSecondary)
  }

  // MARK: - Server Communication

  private func loadRecentProjects() {
    guard let requestEndpointId = resolvedEndpointID(),
          let clients = runtimeRegistry.runtimesByEndpointId[requestEndpointId]?.clients
    else {
      recentProjects = []
      isLoadingRecent = false
      return
    }

    isLoadingRecent = true
    let requestId = UUID()
    recentProjectsRequestId = requestId

    Task { @MainActor in
      defer {
        if ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: recentProjectsRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: resolvedEndpointID()
        ) {
          isLoadingRecent = false
        }
      }

      do {
        let projects = try await clients.filesystem.listRecentProjects()
        guard ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: recentProjectsRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: resolvedEndpointID()
        ) else { return }
        recentProjects = projects
      } catch {
        logger.error("Failed to load recent projects: \(error.localizedDescription)")
        guard ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: recentProjectsRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: resolvedEndpointID()
        ) else { return }
        recentProjects = []
      }
    }
  }

  private func browseDirectory(_ path: String?) {
    guard let requestEndpointId = resolvedEndpointID(),
          let clients = runtimeRegistry.runtimesByEndpointId[requestEndpointId]?.clients
    else {
      directoryEntries = []
      isLoadingDirectory = false
      return
    }

    isLoadingDirectory = true
    let requestId = UUID()
    let historyEntry = currentBrowsePath
    browseRequestId = requestId

    Task { @MainActor in
      defer {
        if ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: browseRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: resolvedEndpointID()
        ) {
          isLoadingDirectory = false
        }
      }

      do {
        let (browsedPath, entries) = try await clients.filesystem.browseDirectory(path: path ?? "")
        guard ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: browseRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: resolvedEndpointID()
        ) else { return }

        let projection = ProjectPickerPlanner.applyBrowseResponse(
          requestedPath: path,
          currentBrowsePath: historyEntry,
          browseHistory: browseHistory,
          browsedPath: browsedPath,
          entries: entries
        )
        browseHistory = projection.browseHistory
        currentBrowsePath = projection.currentBrowsePath
        directoryEntries = projection.directoryEntries
      } catch {
        logger.error("Failed to browse directory: \(error.localizedDescription)")
        guard ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: browseRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: resolvedEndpointID()
        ) else { return }
        directoryEntries = []
      }
    }
  }

  private func navigateBack() {
    guard let previous = browseHistory.last else { return }
    guard let requestEndpointId = resolvedEndpointID(),
          let clients = runtimeRegistry.runtimesByEndpointId[requestEndpointId]?.clients
    else {
      directoryEntries = []
      isLoadingDirectory = false
      return
    }

    isLoadingDirectory = true
    let requestId = UUID()
    browseRequestId = requestId

    Task { @MainActor in
      defer {
        if ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: browseRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: resolvedEndpointID()
        ) {
          isLoadingDirectory = false
        }
      }

      do {
        let (browsedPath, entries) = try await clients.filesystem.browseDirectory(path: previous.isEmpty ? "" : previous)
        guard ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: browseRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: resolvedEndpointID()
        ) else { return }

        guard let projection = ProjectPickerPlanner.applyNavigateBackResponse(
          browseHistory: browseHistory,
          browsedPath: browsedPath,
          entries: entries
        ) else { return }

        browseHistory = projection.browseHistory
        currentBrowsePath = projection.currentBrowsePath
        directoryEntries = projection.directoryEntries
      } catch {
        logger.error("Failed to navigate back in directory browser: \(error.localizedDescription)")
        guard ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: browseRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: resolvedEndpointID()
        ) else { return }
        directoryEntries = []
      }
    }
  }

  private func resolvedEndpointID() -> UUID? {
    ServerEndpointSelection.resolvedEndpointID(
      explicitEndpointID: endpointId,
      primaryEndpointID: runtimeRegistry.primaryEndpointId,
      activeEndpointID: runtimeRegistry.activeEndpointId,
      availableEndpoints: endpointSettings.endpoints()
    )
  }

  private func resetEndpointScopedState() {
    selectedPath = ""
    recentProjects = []
    let projection = ProjectPickerPlanner.resetBrowseProjection()
    directoryEntries = projection.directoryEntries
    currentBrowsePath = projection.currentBrowsePath
    browseHistory = projection.browseHistory
    manualPathText = ""
    loadRecentProjects()
  }
}

#Preview {
  let runtimeRegistry = ServerRuntimeRegistry(
    endpointsProvider: { [] },
    runtimeFactory: { ServerRuntime(endpoint: $0) },
    shouldBootstrapFromSettings: false
  )
  RemoteProjectPicker(selectedPath: .constant(""), endpointId: nil)
    .padding()
    .frame(width: 400)
    .background(Color.backgroundSecondary)
    .environment(runtimeRegistry)
}
