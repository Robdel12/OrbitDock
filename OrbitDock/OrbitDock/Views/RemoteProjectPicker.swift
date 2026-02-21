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
  @Binding var selectedPath: String
  @State private var recentProjects: [ServerRecentProject] = []
  @State private var directoryEntries: [ServerDirectoryEntry] = []
  @State private var currentBrowsePath: String = ""
  @State private var isLoadingRecent = false
  @State private var isLoadingDirectory = false
  @State private var manualPathText: String = ""
  @State private var activeTab: PickerTab = .recent
  @State private var browseHistory: [String] = []

  private enum PickerTab: String, CaseIterable {
    case recent = "Recent"
    case browse = "Browse"
    case manual = "Manual"
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

      tabPicker

      switch activeTab {
        case .recent:
          recentProjectsView
        case .browse:
          directoryBrowserView
        case .manual:
          manualInputView
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

      Text(displayPath(selectedPath))
        .font(.system(size: TypeScale.body, design: .monospaced))
        .foregroundStyle(Color.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)

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
            .frame(maxWidth: .infinity)
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
        .frame(maxHeight: 240)
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
        .frame(maxHeight: 280)
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

  // MARK: - Manual Input

  private var manualInputView: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Enter the full path to your project directory")
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)

      HStack(spacing: Spacing.sm) {
        TextField("~/Developer/my-project", text: $manualPathText)
          .textFieldStyle(.plain)
          .font(.system(size: TypeScale.body, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .padding(Spacing.md)
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md))
        #if os(iOS)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .keyboardType(.URL)
        #endif

        Button {
          let trimmed = manualPathText.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return }
          selectedPath = trimmed
        } label: {
          Text("Use")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(Color.accent, in: RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(manualPathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
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

  // MARK: - Server Communication

  private func loadRecentProjects() {
    isLoadingRecent = true
    let connection = ServerConnection.shared

    connection.onRecentProjectsList = { projects in
      Task { @MainActor in
        self.recentProjects = projects
        self.isLoadingRecent = false
      }
    }

    connection.send(.listRecentProjects)
  }

  private func browseDirectory(_ path: String?) {
    isLoadingDirectory = true
    let connection = ServerConnection.shared

    if let path, !path.isEmpty {
      browseHistory.append(currentBrowsePath)
    }

    connection.onDirectoryListing = { resolvedPath, entries in
      Task { @MainActor in
        self.currentBrowsePath = resolvedPath
        self.directoryEntries = entries
        self.isLoadingDirectory = false
      }
    }

    connection.send(.browseDirectory(path: path))
  }

  private func navigateBack() {
    guard let previous = browseHistory.popLast() else { return }
    isLoadingDirectory = true
    let connection = ServerConnection.shared

    connection.onDirectoryListing = { resolvedPath, entries in
      Task { @MainActor in
        self.currentBrowsePath = resolvedPath
        self.directoryEntries = entries
        self.isLoadingDirectory = false
      }
    }

    connection.send(.browseDirectory(path: previous.isEmpty ? nil : previous))
  }
}

#Preview {
  RemoteProjectPicker(selectedPath: .constant(""))
    .padding()
    .frame(width: 400)
    .background(Color.backgroundSecondary)
}
