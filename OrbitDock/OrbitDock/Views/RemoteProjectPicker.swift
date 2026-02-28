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
  @Binding var selectedPathIsGit: Bool
  let endpointId: UUID?
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

      tabContentCard
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
      selectedPathIsGit = true
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
            selectedPathIsGit = false
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
    manualPathText = ""
    loadRecentProjects()
  }
}

#Preview {
  RemoteProjectPicker(selectedPath: .constant(""), endpointId: nil)
    .padding()
    .frame(width: 400)
    .background(Color.backgroundSecondary)
    .environment(ServerRuntimeRegistry.shared)
}
