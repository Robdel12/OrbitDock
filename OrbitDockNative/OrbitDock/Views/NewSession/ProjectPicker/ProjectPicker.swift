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

  let projectPickerLogger = Logger(subsystem: "com.orbitdock", category: "project-picker")

  struct ProjectPicker: View {
    @Binding var selectedPath: String
    @Binding var selectedPathIsGit: Bool
    let endpointId: UUID?
    let endpointSettings: ServerEndpointSettingsClient
    @Environment(ServerRuntimeRegistry.self) var runtimeRegistry
    @State var recentProjects: [ServerRecentProject] = []
    @State var directoryEntries: [ServerDirectoryEntry] = []
    @State var currentBrowsePath: String = ""
    @State var isLoadingRecent = false
    @State var isLoadingDirectory = false
    @State var activeTab: PickerTab = .recent
    @State var browseHistory: [String] = []
    @State var recentProjectsRequestId = UUID()
    @State var browseRequestId = UUID()

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

    enum PickerTab: String, CaseIterable {
      case recent = "Recent"
      case browse = "Browse"
    }

    var groupedRecentProjects: [GroupedRecentProject] {
      ProjectPickerPlanner.groupedRecentProjects(from: recentProjects)
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
        selectedPathIsGit = false
      }
    }
  }

  #Preview {
    let runtimeRegistry = ServerRuntimeRegistry(
      endpointsProvider: { [] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    ProjectPicker(selectedPath: .constant(""), endpointId: nil)
      .padding()
      .frame(width: 450)
      .background(Color.backgroundSecondary)
      .environment(runtimeRegistry)
  }

#endif
