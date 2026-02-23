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
    @Binding var selectedPath: String
    @State private var recentProjects: [ServerRecentProject] = []
    @State private var directoryEntries: [ServerDirectoryEntry] = []
    @State private var currentBrowsePath: String = ""
    @State private var isLoadingRecent = false
    @State private var isLoadingDirectory = false
    @State private var activeTab: PickerTab = .recent
    @State private var browseHistory: [String] = []
    @State private var recentProjectsRequestId = UUID()
    @State private var browseRequestId = UUID()

    private enum PickerTab: String, CaseIterable {
      case recent = "Recent"
      case browse = "Browse"
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
            HStack(spacing: 4) {
              Image(systemName: "folder.badge.plus")
                .font(.system(size: 11, weight: .medium))
              Text("Finder")
                .font(.system(size: TypeScale.caption, weight: .medium))
            }
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
    }

    // MARK: - Selected Path Banner

    private var selectedPathBanner: some View {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "folder.fill")
          .font(.system(size: 12))
          .foregroundStyle(Color.accent)

        VStack(alignment: .leading, spacing: 2) {
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
      HStack(spacing: 0) {
        ForEach(PickerTab.allCases, id: \.self) { tab in
          Button {
            withAnimation(.easeOut(duration: 0.15)) {
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
            LazyVStack(spacing: 2) {
              ForEach(recentProjects) { project in
                recentProjectRow(project)
              }
            }
          }
          .frame(minHeight: 200, maxHeight: 280)
        }
      }
    }

    private func recentProjectRow(_ project: ServerRecentProject) -> some View {
      Button {
        selectedPath = project.path
      } label: {
        HStack(spacing: Spacing.md) {
          Image(systemName: "folder.fill")
            .font(.system(size: 14))
            .foregroundStyle(Color.accent)

          VStack(alignment: .leading, spacing: 2) {
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

          VStack(alignment: .trailing, spacing: 2) {
            Text("\(project.sessionCount) session\(project.sessionCount == 1 ? "" : "s")")
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accent)
                .frame(width: 28, height: 28)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6))
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
            } label: {
              Text("Use This")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 4)
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
            LazyVStack(spacing: 2) {
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
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())
          } else {
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .medium))
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
      }
    }

    // MARK: - Server Communication

    private func loadRecentProjects() {
      isLoadingRecent = true
      let connection = ServerRuntimeRegistry.shared.activeConnection
      let endpointId = connection.endpointId
      let requestId = UUID()
      recentProjectsRequestId = requestId

      Task { @MainActor in
        defer {
          if recentProjectsRequestId == requestId, ServerRuntimeRegistry.shared.activeEndpointId == endpointId {
            isLoadingRecent = false
          }
        }

        do {
          let projects = try await connection.listRecentProjects()
          guard recentProjectsRequestId == requestId, ServerRuntimeRegistry.shared.activeEndpointId == endpointId else { return }
          recentProjects = projects
        } catch {
          logger.error("Failed to load recent projects: \(error.localizedDescription)")
          guard recentProjectsRequestId == requestId, ServerRuntimeRegistry.shared.activeEndpointId == endpointId else { return }
          recentProjects = []
        }
      }
    }

    private func browseDirectory(_ path: String?) {
      isLoadingDirectory = true
      let connection = ServerRuntimeRegistry.shared.activeConnection
      let endpointId = connection.endpointId
      let requestId = UUID()
      let historyEntry = currentBrowsePath
      browseRequestId = requestId

      Task { @MainActor in
        defer {
          if browseRequestId == requestId, ServerRuntimeRegistry.shared.activeEndpointId == endpointId {
            isLoadingDirectory = false
          }
        }

        do {
          let listing = try await connection.browseDirectory(path: path)
          guard browseRequestId == requestId, ServerRuntimeRegistry.shared.activeEndpointId == endpointId else { return }

          if let path, !path.isEmpty {
            browseHistory.append(historyEntry)
          }
          currentBrowsePath = listing.path
          directoryEntries = listing.entries
        } catch {
          logger.error("Failed to browse directory: \(error.localizedDescription)")
          guard browseRequestId == requestId, ServerRuntimeRegistry.shared.activeEndpointId == endpointId else { return }
          directoryEntries = []
        }
      }
    }

    private func navigateBack() {
      guard let previous = browseHistory.last else { return }
      isLoadingDirectory = true
      let connection = ServerRuntimeRegistry.shared.activeConnection
      let endpointId = connection.endpointId
      let requestId = UUID()
      browseRequestId = requestId

      Task { @MainActor in
        defer {
          if browseRequestId == requestId, ServerRuntimeRegistry.shared.activeEndpointId == endpointId {
            isLoadingDirectory = false
          }
        }

        do {
          let listing = try await connection.browseDirectory(path: previous.isEmpty ? nil : previous)
          guard browseRequestId == requestId, ServerRuntimeRegistry.shared.activeEndpointId == endpointId else { return }

          _ = browseHistory.popLast()
          currentBrowsePath = listing.path
          directoryEntries = listing.entries
        } catch {
          logger.error("Failed to navigate back in directory browser: \(error.localizedDescription)")
          guard browseRequestId == requestId, ServerRuntimeRegistry.shared.activeEndpointId == endpointId else { return }
          directoryEntries = []
        }
      }
    }
  }

  #Preview {
    ProjectPicker(selectedPath: .constant(""))
      .padding()
      .frame(width: 450)
      .background(Color.backgroundSecondary)
  }

#endif
