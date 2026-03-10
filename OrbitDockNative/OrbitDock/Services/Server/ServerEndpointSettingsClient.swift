import Foundation

@MainActor
struct ServerEndpointSettingsClient {
  let endpoints: () -> [ServerEndpoint]
  let defaultEndpoint: () -> ServerEndpoint
  let hasRemoteEndpoint: () -> Bool
  let saveEndpoints: ([ServerEndpoint]) -> Void
  let buildURL: (String) -> URL?
  let hostInput: (URL) -> String?
  let defaultPort: Int

  static func live() -> ServerEndpointSettingsClient {
    ServerEndpointSettingsClient(
      endpoints: { ServerEndpointSettings.endpoints },
      defaultEndpoint: { ServerEndpointSettings.defaultEndpoint },
      hasRemoteEndpoint: { ServerEndpointSettings.hasRemoteEndpoint },
      saveEndpoints: { ServerEndpointSettings.saveEndpoints($0) },
      buildURL: { ServerEndpointSettings.buildURL(from: $0) },
      hostInput: { ServerEndpointSettings.hostInput(from: $0) },
      defaultPort: ServerEndpointSettings.defaultPort
    )
  }
}

enum ServerEndpointSelection {
  static func initialEndpointID(
    continuationEndpointID: UUID?,
    availableEndpoints: [ServerEndpoint],
    fallbackDefaultEndpointID: UUID
  ) -> UUID {
    continuationEndpointID
      ?? availableEndpoints.first(where: \.isDefault)?.id
      ?? availableEndpoints.first?.id
      ?? fallbackDefaultEndpointID
  }

  static func resolvedEndpointID(
    explicitEndpointID: UUID?,
    primaryEndpointID: UUID?,
    activeEndpointID: UUID?,
    availableEndpoints: [ServerEndpoint]
  ) -> UUID? {
    explicitEndpointID
      ?? primaryEndpointID
      ?? activeEndpointID
      ?? ServerRuntimeRegistryPlanner.preferredActiveEndpointID(from: availableEndpoints)
  }
}
