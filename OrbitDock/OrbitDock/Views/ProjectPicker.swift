//
//  ProjectPicker.swift
//  OrbitDock
//
//  macOS project picker with Recent/Browse tabs.
//  Mirrors iOS's RemoteProjectPicker but with native macOS fallbacks.
//

import os.log
import SwiftUI

#if os(macOS)

  private let logger = Logger(subsystem: "com.orbitdock", category: "project-picker")

  struct ProjectPicker: View {
    private struct RecentWorktreeProject: Identifiable {
      let project: ServerRecentProject
      let repoPath: String
      let branchPath: String
      var id: String {
        project.id
      }
    }

    private struct GroupedRecentProject: Identifiable {
      let repoPath: String
      let repoProject: ServerRecentProject?
      let worktrees: [RecentWorktreeProject]
      let totalSessionCount: UInt32
      let lastActive: String?
      var id: String {
        repoPath
      }
    }

    @Binding var selectedPath: String
    @Binding var selectedPathIsGit: Bool
    let endpointId: UUID?
    @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
    @State private var recentProjects: [ServerRecentProject] = []
    @State private var directoryEntries: [ServerDirectoryEntry] = []
    @State private var currentBrowsePath: String = ""
    @State private var isLoadingRecent = false
    @State private var isLoadingDirectory = false
    @State private var activeTab: PickerTab = .recent
    @State private var browseHistory: [String] = []
    @State private var recentProjectsRequestId = UUID()
    @State private var browseRequestId = UUID()

    init(
      selectedPath: Binding<String>,
      selectedPathIsGit: Binding<Bool> = .constant(true),
      endpointId: UUID? = nil
    ) {
      _selectedPath = selectedPath
      _selectedPathIsGit = selectedPathIsGit
      self.endpointId = endpointId
    }

    private enum PickerTab: String, CaseIterable {
      case recent = "Recent"
      case browse = "Browse"
    }

    private var groupedRecentProjects: [GroupedRecentProject] {
      makeGroupedRecentProjects(from: recentProjects)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Text("Project Directory")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
          .textCase(.uppercase)
          .tracking(0.5)

        if !selectedPath.isEmpty {
          selectedPathBanner
        }

        HStack(spacing: Spacing.sm) {
          tabPicker

          Spacer()

          // Native Finder button
          Button {
            openFinderPanel()
          } label: {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "folder.badge.plus")
                .font(.system(size: TypeScale.meta, weight: .medium))
              Text("Finder")
                .font(.system(size: TypeScale.caption, weight: .medium))
            }
            .foregroundStyle(Color.accent)
            .padding(.horizontal, Spacing.md_)
            .padding(.vertical, Spacing.sm_)
            .background(Color.accent.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
          }
          .buttonStyle(.plain)
        }

        switch activeTab {
          case .recent:
            recentProjectsView
          case .browse:
            directoryBrowserView
        }
      }
      .onAppear {
        loadRecentProjects()
      }
      .onChange(of: endpointId) { _, _ in
        resetEndpointScopedState()
      }
    }

    // MARK: - Selected Path Banner

    private var selectedPathBanner: some View {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "folder.fill")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.accent)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(URL(fileURLWithPath: selectedPath).lastPathComponent)
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textPrimary)

          Text(displayPath(selectedPath))
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer()

        Button {
          selectedPath = ""
          selectedPathIsGit = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: TypeScale.subhead))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
      }
      .padding(Spacing.md)
      .background(Color.accent.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
      HStack(spacing: 0) {
        ForEach(PickerTab.allCases, id: \.self) { tab in
          Button {
            withAnimation(Motion.hover) {
              activeTab = tab
            }
            if tab == .browse, directoryEntries.isEmpty {
              browseDirectory(nil)
            }
          } label: {
            Text(tab.rawValue)
              .font(.system(size: TypeScale.body, weight: activeTab == tab ? .semibold : .medium))
              .foregroundStyle(activeTab == tab ? Color.accent : Color.textTertiary)
              .padding(.horizontal, Spacing.lg)
              .padding(.vertical, Spacing.sm)
          }
          .buttonStyle(.plain)
        }
      }
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    // MARK: - Recent Projects

    private var recentProjectsView: some View {
      VStack(alignment: .leading, spacing: Spacing.sm) {
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
            LazyVStack(spacing: Spacing.xxs) {
              ForEach(groupedRecentProjects) { group in
                groupedRecentProjectSection(group)
              }
            }
          }
          .frame(minHeight: 200, maxHeight: 280)
        }
      }
    }

    private func groupedRecentProjectSection(_ group: GroupedRecentProject) -> some View {
      VStack(spacing: Spacing.xxs) {
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
    }

    private func repoProjectRow(
      project: ServerRecentProject,
      worktreeCount: Int,
      totalSessionCount: UInt32
    ) -> some View {
      Button {
        selectedPath = project.path
        selectedPathIsGit = true
      } label: {
        HStack(spacing: Spacing.md) {
          Image(systemName: "folder.fill")
            .font(.system(size: 14))
            .foregroundStyle(Color.accent)

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(URL(fileURLWithPath: project.path).lastPathComponent)
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(Color.textPrimary)

            Text(displayPath(project.path))
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          Spacer()

          HStack(spacing: Spacing.sm) {
            if worktreeCount > 0 {
              Text("\(worktreeCount) worktree\(worktreeCount == 1 ? "" : "s")")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, Spacing.sm_)
                .padding(.vertical, Spacing.xxs)
                .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())
            }

            Text(sessionCountLabel(totalSessionCount))
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textQuaternary)
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          selectedPath == project.path
            ? Color.accent.opacity(OpacityTier.light)
            : Color.clear,
          in: RoundedRectangle(cornerRadius: Radius.md)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.md))
      }
      .buttonStyle(.plain)
    }

    private func syntheticRepoRow(_ group: GroupedRecentProject) -> some View {
      Button {
        selectedPath = group.repoPath
        selectedPathIsGit = true
      } label: {
        HStack(spacing: Spacing.md) {
          Image(systemName: "folder.fill")
            .font(.system(size: 14))
            .foregroundStyle(Color.accent)

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(URL(fileURLWithPath: group.repoPath).lastPathComponent)
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(Color.textPrimary)

            Text(displayPath(group.repoPath))
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          Spacer()

          HStack(spacing: Spacing.sm) {
            Text("\(group.worktrees.count) worktree\(group.worktrees.count == 1 ? "" : "s")")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.accent)
              .padding(.horizontal, Spacing.sm_)
              .padding(.vertical, Spacing.xxs)
              .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())

            Text(sessionCountLabel(group.totalSessionCount))
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textQuaternary)
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          selectedPath == group.repoPath
            ? Color.accent.opacity(OpacityTier.light)
            : Color.clear,
          in: RoundedRectangle(cornerRadius: Radius.md)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.md))
      }
      .buttonStyle(.plain)
    }

    private func worktreeProjectRow(_ worktree: RecentWorktreeProject) -> some View {
      Button {
        selectedPath = worktree.project.path
        selectedPathIsGit = true
      } label: {
        HStack(spacing: Spacing.md) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accent)
            .frame(width: 20)

          VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(worktree.branchPath)
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(Color.textPrimary)

            Text(worktreeRelativePath(worktree))
              .font(.system(size: TypeScale.caption, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          Spacer()

          HStack(spacing: Spacing.sm) {
            Text("worktree")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.accent)
              .padding(.horizontal, Spacing.sm_)
              .padding(.vertical, Spacing.xxs)
              .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())

            Text(sessionCountLabel(worktree.project.sessionCount))
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textQuaternary)
          }
        }
        .padding(.leading, Spacing.xl + Spacing.md)
        .padding(.trailing, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          selectedPath == worktree.project.path
            ? Color.accent.opacity(OpacityTier.light)
            : Color.clear,
          in: RoundedRectangle(cornerRadius: Radius.md)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.md))
      }
      .buttonStyle(.plain)
    }

    // MARK: - Directory Browser

    private var directoryBrowserView: some View {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Breadcrumb / current path
        HStack(spacing: Spacing.sm) {
          if !browseHistory.isEmpty {
            Button {
              navigateBack()
            } label: {
              Image(systemName: "chevron.left")
                .font(.system(size: TypeScale.meta, weight: .semibold))
                .foregroundStyle(Color.accent)
                .frame(width: 28, height: 28)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md))
            }
            .buttonStyle(.plain)
          }

          Text(displayPath(currentBrowsePath))
            .font(.system(size: TypeScale.caption, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .truncationMode(.head)

          Spacer()

          if !currentBrowsePath.isEmpty {
            Button {
              selectedPath = currentBrowsePath
              selectedPathIsGit = false
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
            LazyVStack(spacing: Spacing.xxs) {
              ForEach(directoryEntries.filter(\.isDir)) { entry in
                directoryEntryRow(entry)
              }
            }
          }
          .frame(minHeight: 200, maxHeight: 280)
        }
      }
    }

    private func directoryEntryRow(_ entry: ServerDirectoryEntry) -> some View {
      Button {
        let newPath = currentBrowsePath.isEmpty
          ? entry.name
          : "\(currentBrowsePath)/\(entry.name)"

        if entry.isGit {
          // Git repo — select it as the project path
          selectedPath = newPath
          selectedPathIsGit = true
        } else {
          // Regular dir — navigate into it
          browseDirectory(newPath)
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
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func displayPath(_ path: String) -> String {
      if path.hasPrefix("/Users/") {
        let parts = path.split(separator: "/", maxSplits: 3)
        if parts.count >= 2 {
          return "~/" + (parts.count > 2 ? String(parts[2...].joined(separator: "/")) : "")
        }
      }
      return path.isEmpty ? "~" : path
    }

    private func sessionCountLabel(_ count: UInt32) -> String {
      "\(count) session\(count == 1 ? "" : "s")"
    }

    private func worktreeRelativePath(_ worktree: RecentWorktreeProject) -> String {
      let repoName = URL(fileURLWithPath: worktree.repoPath).lastPathComponent
      return "\(repoName)/.orbitdock-worktrees/\(worktree.branchPath)"
    }

    private func makeGroupedRecentProjects(from projects: [ServerRecentProject]) -> [GroupedRecentProject] {
      struct Accumulator {
        var repoProject: ServerRecentProject?
        var worktrees: [RecentWorktreeProject] = []
        var totalSessionCount: UInt32 = 0
        var lastActive: String?

        mutating func include(_ project: ServerRecentProject) {
          totalSessionCount += project.sessionCount
          if let active = project.lastActive,
             lastActive == nil || active > lastActive!
          {
            lastActive = active
          }
        }
      }

      var grouped: [String: Accumulator] = [:]

      for project in projects {
        if let parsed = parseOrbitDockWorktreePath(project.path) {
          var bucket = grouped[parsed.repoPath] ?? Accumulator()
          bucket.worktrees.append(
            RecentWorktreeProject(project: project, repoPath: parsed.repoPath, branchPath: parsed.branchPath)
          )
          bucket.include(project)
          grouped[parsed.repoPath] = bucket
          continue
        }

        var bucket = grouped[project.path] ?? Accumulator()
        bucket.repoProject = project
        bucket.include(project)
        grouped[project.path] = bucket
      }

      return grouped.map { repoPath, bucket in
        let sortedWorktrees = bucket.worktrees.sorted {
          if $0.project.lastActive == $1.project.lastActive {
            return $0.branchPath < $1.branchPath
          }
          return ($0.project.lastActive ?? "") > ($1.project.lastActive ?? "")
        }

        return GroupedRecentProject(
          repoPath: repoPath,
          repoProject: bucket.repoProject,
          worktrees: sortedWorktrees,
          totalSessionCount: bucket.totalSessionCount,
          lastActive: bucket.lastActive
        )
      }
      .sorted {
        if $0.lastActive == $1.lastActive {
          return $0.repoPath < $1.repoPath
        }
        return ($0.lastActive ?? "") > ($1.lastActive ?? "")
      }
    }

    private func parseOrbitDockWorktreePath(_ path: String) -> (repoPath: String, branchPath: String)? {
      let marker = "/.orbitdock-worktrees/"
      guard let markerRange = path.range(of: marker) else {
        return nil
      }

      let repoPath = String(path[..<markerRange.lowerBound])
      let branchPath = String(path[markerRange.upperBound...])
      guard !repoPath.isEmpty, !branchPath.isEmpty else {
        return nil
      }
      return (repoPath, branchPath)
    }

    private func openFinderPanel() {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = false
      panel.prompt = "Select"
      panel.message = "Choose a project directory"

      panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Developer")

      if panel.runModal() == .OK, let url = panel.url {
        selectedPath = url.path
        selectedPathIsGit = false // Unknown — let the sheet handle verification
      }
    }

    // MARK: - Server Communication

    private func loadRecentProjects() {
      guard let requestEndpointId = resolvedEndpointID(),
            let connection = runtimeRegistry.connection(for: requestEndpointId)
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
          if recentProjectsRequestId == requestId, resolvedEndpointID() == requestEndpointId {
            isLoadingRecent = false
          }
        }

        do {
          let projects = try await connection.listRecentProjects()
          guard recentProjectsRequestId == requestId, resolvedEndpointID() == requestEndpointId else { return }
          recentProjects = projects
        } catch {
          logger.error("Failed to load recent projects: \(error.localizedDescription)")
          guard recentProjectsRequestId == requestId, resolvedEndpointID() == requestEndpointId else { return }
          recentProjects = []
        }
      }
    }

    private func browseDirectory(_ path: String?) {
      guard let requestEndpointId = resolvedEndpointID(),
            let connection = runtimeRegistry.connection(for: requestEndpointId)
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
          if browseRequestId == requestId, resolvedEndpointID() == requestEndpointId {
            isLoadingDirectory = false
          }
        }

        do {
          let listing = try await connection.browseDirectory(path: path)
          guard browseRequestId == requestId, resolvedEndpointID() == requestEndpointId else { return }

          if let path, !path.isEmpty {
            browseHistory.append(historyEntry)
          }
          currentBrowsePath = listing.path
          directoryEntries = listing.entries
        } catch {
          logger.error("Failed to browse directory: \(error.localizedDescription)")
          guard browseRequestId == requestId, resolvedEndpointID() == requestEndpointId else { return }
          directoryEntries = []
        }
      }
    }

    private func navigateBack() {
      guard let previous = browseHistory.last else { return }
      guard let requestEndpointId = resolvedEndpointID(),
            let connection = runtimeRegistry.connection(for: requestEndpointId)
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
          if browseRequestId == requestId, resolvedEndpointID() == requestEndpointId {
            isLoadingDirectory = false
          }
        }

        do {
          let listing = try await connection.browseDirectory(path: previous.isEmpty ? nil : previous)
          guard browseRequestId == requestId, resolvedEndpointID() == requestEndpointId else { return }

          _ = browseHistory.popLast()
          currentBrowsePath = listing.path
          directoryEntries = listing.entries
        } catch {
          logger.error("Failed to navigate back in directory browser: \(error.localizedDescription)")
          guard browseRequestId == requestId, resolvedEndpointID() == requestEndpointId else { return }
          directoryEntries = []
        }
      }
    }

    private func resolvedEndpointID() -> UUID? {
      endpointId
        ?? runtimeRegistry.primaryEndpointId
        ?? runtimeRegistry.activeEndpointId
        ?? ServerRuntimeRegistry.preferredActiveEndpointID(from: ServerEndpointSettings.endpoints)
    }

    private func resetEndpointScopedState() {
      selectedPath = ""
      recentProjects = []
      directoryEntries = []
      currentBrowsePath = ""
      browseHistory = []
      loadRecentProjects()
    }
  }

  #Preview {
    ProjectPicker(selectedPath: .constant(""), endpointId: nil)
      .padding()
      .frame(width: 450)
      .background(Color.backgroundSecondary)
      .environment(ServerRuntimeRegistry.shared)
  }

#endif
