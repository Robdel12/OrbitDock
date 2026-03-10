//
//  RemoteProjectPicker.swift
//  OrbitDock
//
//  Remote project picker for iOS — browses server filesystem.
//  Shows recent projects, directory browser, and manual path input.
//

import os.log
import SwiftUI

let remoteProjectPickerLogger = Logger(subsystem: "com.orbitdock", category: "remote-project-picker")

struct RemoteProjectPicker: View {
  struct PathPreviewItem: Identifiable {
    let title: String
    let path: String
    let id = UUID()
  }

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
  @State var manualPathText: String = ""
  @State var activeTab: PickerTab = .recent
  @State var browseHistory: [String] = []
  @State var recentProjectsRequestId = UUID()
  @State var browseRequestId = UUID()
  @State var pathPreview: PathPreviewItem?

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
    case manual = "Manual"
  }

  var groupedRecentProjects: [GroupedRecentProject] {
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

  var selectedPathBanner: some View {
    RemoteProjectPickerSelectedPathBanner(
      selectedPath: selectedPath,
      onCopy: { Platform.services.copyToClipboard(selectedPath) },
      onClear: {
        selectedPath = ""
        selectedPathIsGit = true
      }
    )
  }

  var tabPicker: some View {
    RemoteProjectPickerTabPicker(
      tabs: PickerTab.allCases,
      activeTab: activeTab,
      title: \.rawValue,
      onSelect: { tab in
        activeTab = tab
        if tab == .browse, directoryEntries.isEmpty {
          browseDirectory(nil)
        }
      }
    )
  }

  var tabContentCard: some View {
    RemoteProjectPickerTabContentCard {
      switch activeTab {
        case .recent:
          recentProjectsView
        case .browse:
          directoryBrowserView
        case .manual:
          manualInputView
      }
    }
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
