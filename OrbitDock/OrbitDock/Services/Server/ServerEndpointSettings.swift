import Foundation

/// Persisted server endpoint configuration.
/// Stores the remote server host (and optional port) in UserDefaults.
/// We control both sides so we construct the full ws:// URL automatically.
enum ServerEndpointSettings {
  private static let remoteHostKey = "orbitdock.server.remote_host"
  static let defaultPort = 4_000

  /// The saved remote host string (e.g. "192.168.1.100" or "192.168.1.100:4001").
  /// Returns nil if no remote endpoint is configured.
  static var remoteHost: String? {
    get { UserDefaults.standard.string(forKey: remoteHostKey) }
    set {
      if let host = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
        UserDefaults.standard.set(host, forKey: remoteHostKey)
      } else {
        UserDefaults.standard.removeObject(forKey: remoteHostKey)
      }
    }
  }

  /// The full WebSocket URL built from the saved host, or nil if not configured.
  static var remoteURL: URL? {
    guard let host = remoteHost else { return nil }
    return buildURL(from: host)
  }

  /// The effective WebSocket URL — remote if configured, otherwise localhost.
  static var effectiveURL: URL {
    remoteURL ?? URL(string: "ws://127.0.0.1:\(defaultPort)/ws")!
  }

  /// Build a ws:// URL from a host string like "192.168.1.100" or "10.0.0.5:4001".
  static func buildURL(from input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Strip any accidental protocol prefix
    let hostPort: String = if trimmed.hasPrefix("ws://") {
      String(trimmed.dropFirst(5))
    } else if trimmed.hasPrefix("wss://") {
      String(trimmed.dropFirst(6))
    } else if trimmed.hasPrefix("http://") {
      String(trimmed.dropFirst(7))
    } else {
      trimmed
    }

    // Strip any trailing path
    let clean = hostPort.split(separator: "/").first.map(String.init) ?? hostPort

    // Add default port if missing
    let withPort: String = if clean.contains(":") {
      clean
    } else {
      "\(clean):\(defaultPort)"
    }

    return URL(string: "ws://\(withPort)/ws")
  }
}
