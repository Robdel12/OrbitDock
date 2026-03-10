import os.log
import SwiftUI

#if os(macOS)

  extension ProjectPicker {
    func loadRecentProjects() {
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

      Task<Void, Never> { @MainActor in
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
          guard shouldApplyResponse(requestId: requestId, requestEndpointId: requestEndpointId, activeRequestId: recentProjectsRequestId)
          else { return }
          recentProjects = projects
        } catch {
          projectPickerLogger.error("Failed to load recent projects: \(error.localizedDescription, privacy: .public)")
          guard shouldApplyResponse(requestId: requestId, requestEndpointId: requestEndpointId, activeRequestId: recentProjectsRequestId)
          else { return }
          recentProjects = []
        }
      }
    }

    func browseDirectory(_ path: String?) {
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

      Task<Void, Never> { @MainActor in
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
          guard shouldApplyResponse(requestId: requestId, requestEndpointId: requestEndpointId, activeRequestId: browseRequestId)
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
          projectPickerLogger.error("Failed to browse directory: \(error.localizedDescription, privacy: .public)")
          guard shouldApplyResponse(requestId: requestId, requestEndpointId: requestEndpointId, activeRequestId: browseRequestId)
          else { return }
          directoryEntries = []
        }
      }
    }

    func navigateBack() {
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

      Task<Void, Never> { @MainActor in
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
          guard shouldApplyResponse(requestId: requestId, requestEndpointId: requestEndpointId, activeRequestId: browseRequestId)
          else { return }
          guard let projection = ProjectPickerPlanner.applyNavigateBackResponse(
            browseHistory: browseHistory,
            browsedPath: browsedPath,
            entries: entries
          ) else { return }
          applyBrowseProjection(projection)
        } catch {
          projectPickerLogger.error("Failed to navigate back in directory browser: \(error.localizedDescription, privacy: .public)")
          guard shouldApplyResponse(requestId: requestId, requestEndpointId: requestEndpointId, activeRequestId: browseRequestId)
          else { return }
          directoryEntries = []
        }
      }
    }

    func resolvedEndpointID() -> UUID? {
      ServerEndpointSelection.resolvedEndpointID(
        explicitEndpointID: endpointId,
        primaryEndpointID: runtimeRegistry.primaryEndpointId,
        activeEndpointID: runtimeRegistry.activeEndpointId,
        availableEndpoints: endpointSettings.endpoints()
      )
    }

    func resetEndpointScopedState() {
      selectedPath = ""
      recentProjects = []
      applyBrowseProjection(ProjectPickerPlanner.resetBrowseProjection())
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
        activeEndpointId: resolvedEndpointID()
      )
    }
  }

#endif
