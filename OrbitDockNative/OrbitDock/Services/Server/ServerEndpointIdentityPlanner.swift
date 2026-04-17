import Foundation

@MainActor
enum ServerEndpointIdentityPlanner {
  static func dedupedRuntimes(_ runtimes: [ServerRuntime]) -> [ServerRuntime] {
    var keptByIdentity: [String: ServerRuntime] = [:]
    var identityOrder: [String] = []

    for runtime in runtimes {
      let identity = identity(for: runtime)
      guard let existing = keptByIdentity[identity] else {
        keptByIdentity[identity] = runtime
        identityOrder.append(identity)
        continue
      }

      if !existing.endpoint.isDefault && runtime.endpoint.isDefault {
        keptByIdentity[identity] = runtime
      }
    }

    return identityOrder.compactMap { keptByIdentity[$0] }
  }

  static func identity(for runtime: ServerRuntime) -> String {
    if let serverInstanceId = runtime.endpointStore.serverInstanceId?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !serverInstanceId.isEmpty
    {
      return "server:\(serverInstanceId)"
    }
    return identity(for: runtime.endpoint.wsURL)
  }

  static func identity(for wsURL: URL) -> String {
    guard let components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
      return "url:\(wsURL.absoluteString.lowercased())"
    }

    let scheme = (components.scheme ?? "ws").lowercased()
    let host = (components.host ?? "").lowercased()
    let port = components.port ?? (scheme == "wss" ? 443 : 80)
    var path = components.percentEncodedPath

    if path.isEmpty {
      path = "/ws"
    }

    while path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }

    let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
    return "url:\(scheme)://\(host):\(port)\(path)\(query)"
  }
}
