import os.log
import SwiftUI

extension RemoteProjectPicker {
  func loadRecentProjects() {
    guard let resolved = ProjectPickerDataAccess.filesystemPort(
      explicitEndpointID: endpointId,
      endpointSettings: endpointSettings,
      runtimeRegistry: runtimeRegistry
    )
    else {
      recentProjects = []
      isLoadingRecent = false
      return
    }
    let requestEndpointId = resolved.endpointId

    isLoadingRecent = true
    let requestId = UUID()
    recentProjectsRequestId = requestId

    Task<Void, Never> { @MainActor in
      defer {
        if ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: recentProjectsRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: ProjectPickerDataAccess.filesystemPort(
            explicitEndpointID: endpointId,
            endpointSettings: endpointSettings,
            runtimeRegistry: runtimeRegistry
          )?.endpointId
        ) {
          isLoadingRecent = false
        }
      }

      do {
        let projects = try await resolved.port.listRecentProjects()
        guard shouldApplyResponse(
          requestId: requestId,
          requestEndpointId: requestEndpointId,
          activeRequestId: recentProjectsRequestId
        )
        else { return }
        recentProjects = projects
      } catch {
        remoteProjectPickerLogger.error("Failed to load recent projects: \(error.localizedDescription)")
        guard shouldApplyResponse(
          requestId: requestId,
          requestEndpointId: requestEndpointId,
          activeRequestId: recentProjectsRequestId
        )
        else { return }
        recentProjects = []
      }
    }
  }

  func browseDirectory(_ path: String?) {
    guard let resolved = ProjectPickerDataAccess.filesystemPort(
      explicitEndpointID: endpointId,
      endpointSettings: endpointSettings,
      runtimeRegistry: runtimeRegistry
    )
    else {
      directoryEntries = []
      isLoadingDirectory = false
      return
    }
    let requestEndpointId = resolved.endpointId

    isLoadingDirectory = true
    let requestId = UUID()
    let historyEntry = currentBrowsePath
    browseRequestId = requestId

    Task<Void, Never> { @MainActor in
      defer {
        if ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: browseRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: ProjectPickerDataAccess.filesystemPort(
            explicitEndpointID: endpointId,
            endpointSettings: endpointSettings,
            runtimeRegistry: runtimeRegistry
          )?.endpointId
        ) {
          isLoadingDirectory = false
        }
      }

      do {
        let (browsedPath, entries) = try await resolved.port.browseDirectory(path ?? "")
        guard shouldApplyResponse(
          requestId: requestId,
          requestEndpointId: requestEndpointId,
          activeRequestId: browseRequestId
        )
        else { return }

        let projection = ProjectPickerPlanner.applyBrowseResponse(
          requestedPath: path,
          currentBrowsePath: historyEntry,
          browseHistory: browseHistory,
          browsedPath: browsedPath,
          entries: entries
        )
        applyBrowseProjection(projection)
      } catch {
        remoteProjectPickerLogger.error("Failed to browse directory: \(error.localizedDescription)")
        guard shouldApplyResponse(
          requestId: requestId,
          requestEndpointId: requestEndpointId,
          activeRequestId: browseRequestId
        )
        else { return }
        directoryEntries = []
      }
    }
  }

  func navigateBack() {
    guard let previous = browseHistory.last else { return }
    guard let resolved = ProjectPickerDataAccess.filesystemPort(
      explicitEndpointID: endpointId,
      endpointSettings: endpointSettings,
      runtimeRegistry: runtimeRegistry
    )
    else {
      directoryEntries = []
      isLoadingDirectory = false
      return
    }
    let requestEndpointId = resolved.endpointId

    isLoadingDirectory = true
    let requestId = UUID()
    browseRequestId = requestId

    Task<Void, Never> { @MainActor in
      defer {
        if ProjectPickerPlanner.shouldApplyResponse(
          requestId: requestId,
          activeRequestId: browseRequestId,
          requestEndpointId: requestEndpointId,
          activeEndpointId: ProjectPickerDataAccess.filesystemPort(
            explicitEndpointID: endpointId,
            endpointSettings: endpointSettings,
            runtimeRegistry: runtimeRegistry
          )?.endpointId
        ) {
          isLoadingDirectory = false
        }
      }

      do {
        let (browsedPath, entries) = try await resolved.port.browseDirectory(previous.isEmpty ? "" : previous)
        guard shouldApplyResponse(
          requestId: requestId,
          requestEndpointId: requestEndpointId,
          activeRequestId: browseRequestId
        )
        else { return }
        guard let projection = ProjectPickerPlanner.applyNavigateBackResponse(
          browseHistory: browseHistory,
          browsedPath: browsedPath,
          entries: entries
        ) else { return }
        applyBrowseProjection(projection)
      } catch {
        remoteProjectPickerLogger.error("Failed to navigate back in directory browser: \(error.localizedDescription)")
        guard shouldApplyResponse(
          requestId: requestId,
          requestEndpointId: requestEndpointId,
          activeRequestId: browseRequestId
        )
        else { return }
        directoryEntries = []
      }
    }
  }

  func resetEndpointScopedState() {
    selectedPath = ""
    recentProjects = []
    applyBrowseProjection(ProjectPickerPlanner.resetBrowseProjection())
    manualPathText = ""
    loadRecentProjects()
  }

  private func applyBrowseProjection(_ projection: ProjectPickerBrowseProjection) {
    browseHistory = projection.browseHistory
    currentBrowsePath = projection.currentBrowsePath
    directoryEntries = projection.directoryEntries
  }

  private func shouldApplyResponse(requestId: UUID, requestEndpointId: UUID, activeRequestId: UUID) -> Bool {
    ProjectPickerPlanner.shouldApplyResponse(
      requestId: requestId,
      activeRequestId: activeRequestId,
      requestEndpointId: requestEndpointId,
      activeEndpointId: ProjectPickerDataAccess.filesystemPort(
        explicitEndpointID: endpointId,
        endpointSettings: endpointSettings,
        runtimeRegistry: runtimeRegistry
      )?.endpointId
    )
  }
}
