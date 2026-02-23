import Foundation

/// Persisted server endpoint configuration.
enum ServerEndpointSettings {
  static let defaultPort = 4_000
  private static let store = ServerEndpointStore()

  static var endpoints: [ServerEndpoint] {
    store.endpoints()
  }

  static var defaultEndpoint: ServerEndpoint {
    store.defaultEndpoint()
  }

  static var remoteEndpoint: ServerEndpoint? {
    store.remoteEndpoint()
  }

  static var hasRemoteEndpoint: Bool {
    store.hasRemoteEndpoint()
  }

  static var effectiveURL: URL {
    store.effectiveURL()
  }

  static func saveEndpoints(_ endpoints: [ServerEndpoint]) {
    store.save(endpoints)
  }

  static func upsertEndpoint(_ endpoint: ServerEndpoint) {
    store.upsert(endpoint)
  }

  static func removeEndpoint(id: UUID) {
    store.remove(id: id)
  }

  static func setDefaultEndpoint(id: UUID) {
    store.setDefaultEndpoint(id: id)
  }

  static func setEndpointEnabled(id: UUID, isEnabled: Bool) {
    store.setEndpointEnabled(id: id, isEnabled: isEnabled)
  }

  static func replaceRemoteEndpoint(hostInput: String) {
    store.replaceRemoteEndpoint(hostInput: hostInput)
  }

  static func clearRemoteEndpoints() {
    store.clearRemoteEndpoints()
  }

  /// Build a ws:// URL from a host string like "192.168.1.100" or "10.0.0.5:4001".
  static func buildURL(from input: String) -> URL? {
    ServerEndpointStore.buildURL(fromHostInput: input, defaultPort: defaultPort)
  }

  static func hostInput(from url: URL) -> String? {
    ServerEndpointStore.hostInput(from: url, defaultPort: defaultPort)
  }
}
