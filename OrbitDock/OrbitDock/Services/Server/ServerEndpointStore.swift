import Foundation

struct ServerEndpointStore {
  static let endpointsStorageKey = "orbitdock.server.endpoints"
  static let legacyRemoteHostStorageKey = "orbitdock.server.remote_host"

  private let defaults: UserDefaults
  private let endpointsKey: String
  private let legacyRemoteHostKey: String
  private let defaultPort: Int
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults = .standard,
    endpointsKey: String = ServerEndpointStore.endpointsStorageKey,
    legacyRemoteHostKey: String = ServerEndpointStore.legacyRemoteHostStorageKey,
    defaultPort: Int = ServerEndpointSettings.defaultPort
  ) {
    self.defaults = defaults
    self.endpointsKey = endpointsKey
    self.legacyRemoteHostKey = legacyRemoteHostKey
    self.defaultPort = defaultPort
  }

  func endpoints() -> [ServerEndpoint] {
    if let persisted = persistedEndpoints() {
      let normalized = normalizedEndpoints(persisted)
      if normalized != persisted {
        save(normalized)
      }
      return normalized
    }

    // Migrate once from the legacy `remote_host` key or seed with localhost.
    let migrated = migratedOrSeededEndpoints()
    save(migrated)
    return migrated
  }

  func defaultEndpoint() -> ServerEndpoint {
    let current = endpoints()
    return current.first(where: { $0.isDefault && $0.isEnabled })
      ?? current.first(where: \.isEnabled)
      ?? ServerEndpoint.localDefault(defaultPort: defaultPort)
  }

  func effectiveURL() -> URL {
    defaultEndpoint().wsURL
  }

  func legacyRemoteHost() -> String? {
    if let legacy = sanitizedHost(defaults.string(forKey: legacyRemoteHostKey)) {
      return legacy
    }

    let remoteEndpoint = endpoints().first(where: { $0.isRemote && $0.isDefault })
      ?? endpoints().first(where: \.isRemote)
    return remoteEndpoint.flatMap { hostPortString(from: $0.wsURL) }
  }

  func setLegacyRemoteHost(_ newValue: String?) {
    let sanitized = sanitizedHost(newValue)
    if let sanitized {
      defaults.set(sanitized, forKey: legacyRemoteHostKey)
    } else {
      defaults.removeObject(forKey: legacyRemoteHostKey)
    }

    var updated = endpoints()
    updated.removeAll(where: { !$0.isLocalManaged })

    if let sanitized, let remoteURL = Self.buildURL(fromHostInput: sanitized, defaultPort: defaultPort) {
      for idx in updated.indices {
        updated[idx].isDefault = false
      }
      updated.append(
        ServerEndpoint(
          name: "Remote Server",
          wsURL: remoteURL,
          isLocalManaged: false,
          isEnabled: true,
          isDefault: true
        )
      )
    }

    save(updated)
  }

  func save(_ rawEndpoints: [ServerEndpoint]) {
    let normalized = normalizedEndpoints(rawEndpoints)
    guard let data = try? encoder.encode(normalized) else { return }
    defaults.set(data, forKey: endpointsKey)
  }

  func upsert(_ endpoint: ServerEndpoint) {
    var updated = endpoints()
    if let index = updated.firstIndex(where: { $0.id == endpoint.id }) {
      updated[index] = endpoint
    } else {
      updated.append(endpoint)
    }
    save(updated)
  }

  func remove(id: UUID) {
    var updated = endpoints()
    updated.removeAll(where: { $0.id == id })
    save(updated)
  }

  func setDefaultEndpoint(id: UUID) {
    var updated = endpoints()
    guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
    for idx in updated.indices {
      updated[idx].isDefault = idx == index
    }
    updated[index].isEnabled = true
    save(updated)
  }

  func setEndpointEnabled(id: UUID, isEnabled: Bool) {
    var updated = endpoints()
    guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
    updated[index].isEnabled = isEnabled
    save(updated)
  }

  private func persistedEndpoints() -> [ServerEndpoint]? {
    guard let data = defaults.data(forKey: endpointsKey), !data.isEmpty else {
      return nil
    }
    return try? decoder.decode([ServerEndpoint].self, from: data)
  }

  private func migratedOrSeededEndpoints() -> [ServerEndpoint] {
    var local = ServerEndpoint.localDefault(defaultPort: defaultPort)

    guard
      let host = sanitizedHost(defaults.string(forKey: legacyRemoteHostKey)),
      let remoteURL = Self.buildURL(fromHostInput: host, defaultPort: defaultPort)
    else {
      return [local]
    }

    local.isDefault = false
    return normalizedEndpoints([
      local,
      ServerEndpoint(
        name: "Remote Server",
        wsURL: remoteURL,
        isLocalManaged: false,
        isEnabled: true,
        isDefault: true
      ),
    ])
  }

  private func normalizedEndpoints(_ rawEndpoints: [ServerEndpoint]) -> [ServerEndpoint] {
    var endpoints = rawEndpoints

    if endpoints.isEmpty {
      endpoints = [ServerEndpoint.localDefault(defaultPort: defaultPort)]
    }

    var seen = Set<UUID>()
    endpoints = endpoints.filter { seen.insert($0.id).inserted }

    if !endpoints.contains(where: \.isLocalManaged) {
      let shouldBeDefault = !endpoints.contains(where: { $0.isDefault && $0.isEnabled })
      var local = ServerEndpoint.localDefault(defaultPort: defaultPort)
      local.isDefault = shouldBeDefault
      endpoints.append(local)
    }

    if !endpoints.contains(where: \.isEnabled) {
      if let localIndex = endpoints.firstIndex(where: \.isLocalManaged) {
        endpoints[localIndex].isEnabled = true
      } else if let first = endpoints.indices.first {
        endpoints[first].isEnabled = true
      }
    }

    let defaultIndex = endpoints.firstIndex(where: { $0.isDefault && $0.isEnabled })
      ?? endpoints.firstIndex(where: \.isEnabled)
      ?? 0

    for idx in endpoints.indices {
      endpoints[idx].isDefault = idx == defaultIndex
    }

    return endpoints
  }

  private func sanitizedHost(_ input: String?) -> String? {
    guard let input else { return nil }
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let hostPort: String
    if trimmed.hasPrefix("ws://") {
      hostPort = String(trimmed.dropFirst(5))
    } else if trimmed.hasPrefix("wss://") {
      hostPort = String(trimmed.dropFirst(6))
    } else if trimmed.hasPrefix("http://") {
      hostPort = String(trimmed.dropFirst(7))
    } else {
      hostPort = trimmed
    }

    let clean = hostPort.split(separator: "/").first.map(String.init) ?? hostPort
    return clean.isEmpty ? nil : clean
  }

  private func hostPortString(from url: URL) -> String? {
    guard let host = url.host else { return nil }
    if let port = url.port, port != defaultPort {
      return "\(host):\(port)"
    }
    return host
  }

  static func buildURL(fromHostInput input: String, defaultPort: Int) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let hostPort: String
    if trimmed.hasPrefix("ws://") {
      hostPort = String(trimmed.dropFirst(5))
    } else if trimmed.hasPrefix("wss://") {
      hostPort = String(trimmed.dropFirst(6))
    } else if trimmed.hasPrefix("http://") {
      hostPort = String(trimmed.dropFirst(7))
    } else {
      hostPort = trimmed
    }

    let clean = hostPort.split(separator: "/").first.map(String.init) ?? hostPort
    guard !clean.isEmpty else { return nil }

    let withPort = clean.contains(":") ? clean : "\(clean):\(defaultPort)"
    return URL(string: "ws://\(withPort)/ws")
  }
}
