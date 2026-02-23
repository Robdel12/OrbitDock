import Foundation

/// Persisted server endpoint configuration.
/// Legacy API is retained, but storage now lives in `ServerEndpointStore`.
enum ServerEndpointSettings {
  static let defaultPort = 4_000
  private static let store = ServerEndpointStore()

  static var endpoints: [ServerEndpoint] {
    store.endpoints()
  }

  static var defaultEndpoint: ServerEndpoint {
    store.defaultEndpoint()
  }

  /// The saved remote host string (e.g. "192.168.1.100" or "192.168.1.100:4001").
  /// Returns nil if no remote endpoint is configured.
  static var remoteHost: String? {
    get { store.legacyRemoteHost() }
    set { store.setLegacyRemoteHost(newValue) }
  }

  /// The full WebSocket URL built from the saved host, or nil if not configured.
  static var remoteURL: URL? {
    guard let host = remoteHost else { return nil }
    return buildURL(from: host)
  }

  /// The effective WebSocket URL — remote if configured, otherwise localhost.
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

  /// Build a ws:// URL from a host string like "192.168.1.100" or "10.0.0.5:4001".
  static func buildURL(from input: String) -> URL? {
    ServerEndpointStore.buildURL(fromHostInput: input, defaultPort: defaultPort)
  }
}
