import Foundation

struct ProjectPickerFilesystemPort {
  let listRecentProjects: @Sendable () async throws -> [ServerRecentProject]
  let browseDirectory: @Sendable (_ path: String) async throws -> (String, [ServerDirectoryEntry])
}

enum ProjectPickerDataAccess {
  @MainActor
  static func filesystemPort(
    explicitEndpointID: UUID?,
    endpointSettings: ServerEndpointSettingsClient,
    runtimeRegistry: ServerRuntimeRegistry
  ) -> (endpointId: UUID, port: ProjectPickerFilesystemPort)? {
    guard let endpointId = ServerEndpointSelection.resolvedEndpointID(
      explicitEndpointID: explicitEndpointID,
      primaryEndpointID: runtimeRegistry.primaryEndpointId,
      activeEndpointID: runtimeRegistry.activeEndpointId,
      availableEndpoints: endpointSettings.endpoints()
    ),
    let clients = runtimeRegistry.runtimesByEndpointId[endpointId]?.clients
    else {
      return nil
    }

    return (
      endpointId,
      ProjectPickerFilesystemPort(
        listRecentProjects: { try await clients.filesystem.listRecentProjects() },
        browseDirectory: { path in try await clients.filesystem.browseDirectory(path: path) }
      )
    )
  }
}
