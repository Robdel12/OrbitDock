import Foundation

struct ServerEndpointStore {
  static let endpointsStorageKey = "orbitdock.server.endpoints"

  private let defaults: UserDefaults
  private let endpointsKey: String
  private let defaultPort: Int
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults = .standard,
    endpointsKey: String = ServerEndpointStore.endpointsStorageKey,
    defaultPort: Int = ServerEndpointSettings.defaultPort
  ) {
    self.defaults = defaults
    self.endpointsKey = endpointsKey
    self.defaultPort = defaultPort
  }

  func endpoints() -> [ServerEndpoint] {
    guard let persisted = persistedEndpoints() else {
      let seeded = [ServerEndpoint.localDefault(defaultPort: defaultPort)]
      save(seeded)
      return seeded
    }

    let normalized = normalizedEndpoints(persisted)
    if normalized != persisted {
      save(normalized)
    }
    return normalized
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

  func remoteEndpoint() -> ServerEndpoint? {
    endpoints().first(where: { $0.isRemote && $0.isDefault })
      ?? endpoints().first(where: \.isRemote)
  }

  func hasRemoteEndpoint() -> Bool {
    remoteEndpoint() != nil
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

  func replaceRemoteEndpoint(hostInput: String) {
    guard let remoteURL = Self.buildURL(fromHostInput: hostInput, defaultPort: defaultPort) else {
      return
    }

    var updated = endpoints().filter(\.isLocalManaged)
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
    save(updated)
  }

  func clearRemoteEndpoints() {
    let kept = endpoints().filter(\.isLocalManaged)
    save(kept)
  }

  private func persistedEndpoints() -> [ServerEndpoint]? {
    guard let data = defaults.data(forKey: endpointsKey), !data.isEmpty else {
      return nil
    }
    return try? decoder.decode([ServerEndpoint].self, from: data)
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

  static func hostInput(from url: URL, defaultPort: Int) -> String? {
    guard let host = url.host else { return nil }
    if let port = url.port, port != defaultPort {
      return "\(host):\(port)"
    }
    return host
  }
}
