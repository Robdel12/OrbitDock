import Foundation
import Security

struct ServerEndpointStore {
  static let endpointsStorageKey = "orbitdock.server.endpoints"
  static let endpointTokenIdsStorageKey = "orbitdock.server.endpoint-token-ids"

  private let defaults: UserDefaults
  private let endpointsKey: String
  private let endpointTokenIdsKey: String
  private let defaultPort: Int
  private let tokenStore: ServerEndpointTokenStore
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private static let includesLocalManagedEndpoint = false

  init(
    defaults: UserDefaults = .standard,
    endpointsKey: String = ServerEndpointStore.endpointsStorageKey,
    endpointTokenIdsKey: String = ServerEndpointStore.endpointTokenIdsStorageKey,
    tokenStore: ServerEndpointTokenStore = ServerEndpointTokenStore(),
    defaultPort: Int = ServerEndpointSettings.defaultPort
  ) {
    self.defaults = defaults
    self.endpointsKey = endpointsKey
    self.endpointTokenIdsKey = endpointTokenIdsKey
    self.tokenStore = tokenStore
    self.defaultPort = defaultPort
  }

  func endpoints() -> [ServerEndpoint] {
    guard let persisted = persistedEndpoints() else {
      let seeded = Self.includesLocalManagedEndpoint
        ? [ServerEndpoint.localDefault(defaultPort: defaultPort)]
        : []
      save(seeded)
      return seeded
    }

    let normalized = normalizedEndpoints(persisted)
    let hydrated = hydratedEndpoints(normalized)
    let containsInlineTokens = normalized.contains(where: { Self.normalizedToken($0.authToken) != nil })
    if normalized != persisted || containsInlineTokens {
      save(hydrated)
    }
    return hydrated
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
    syncAuthTokens(from: normalized)
    let redacted = normalized.map { endpoint -> ServerEndpoint in
      var copy = endpoint
      copy.authToken = nil
      return copy
    }
    guard let data = try? encoder.encode(redacted) else { return }
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

  private func hydratedEndpoints(_ endpoints: [ServerEndpoint]) -> [ServerEndpoint] {
    endpoints.map { endpoint in
      var copy = endpoint
      copy.authToken = tokenStore.token(for: endpoint.id) ?? Self.normalizedToken(endpoint.authToken)
      return copy
    }
  }

  private func syncAuthTokens(from endpoints: [ServerEndpoint]) {
    let currentIds = Set(endpoints.map { $0.id.uuidString })
    let previousIds = Set(defaults.stringArray(forKey: endpointTokenIdsKey) ?? [])

    for removedId in previousIds.subtracting(currentIds) {
      tokenStore.remove(forEndpointID: removedId)
    }

    for endpoint in endpoints {
      tokenStore.set(Self.normalizedToken(endpoint.authToken), for: endpoint.id)
    }

    defaults.set(Array(currentIds).sorted(), forKey: endpointTokenIdsKey)
  }

  private func normalizedEndpoints(_ rawEndpoints: [ServerEndpoint]) -> [ServerEndpoint] {
    var endpoints = rawEndpoints
    if !Self.includesLocalManagedEndpoint {
      endpoints.removeAll(where: \.isLocalManaged)
    }

    if endpoints.isEmpty && Self.includesLocalManagedEndpoint {
      endpoints = [ServerEndpoint.localDefault(defaultPort: defaultPort)]
    }

    var seen = Set<UUID>()
    endpoints = endpoints.filter { seen.insert($0.id).inserted }

    if Self.includesLocalManagedEndpoint && !endpoints.contains(where: \.isLocalManaged) {
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

    let forceSecure: Bool
    let hostPort: String

    if trimmed.hasPrefix("wss://") {
      forceSecure = true
      hostPort = String(trimmed.dropFirst(6))
    } else if trimmed.hasPrefix("https://") {
      forceSecure = true
      hostPort = String(trimmed.dropFirst(8))
    } else if trimmed.hasPrefix("ws://") {
      forceSecure = false
      hostPort = String(trimmed.dropFirst(5))
    } else if trimmed.hasPrefix("http://") {
      forceSecure = false
      hostPort = String(trimmed.dropFirst(7))
    } else {
      forceSecure = false
      hostPort = trimmed
    }

    let clean = hostPort.split(separator: "/").first.map(String.init) ?? hostPort
    guard !clean.isEmpty else { return nil }

    if forceSecure {
      // TLS — use wss://, no default port (443 is implicit)
      return URL(string: "wss://\(clean)/ws")
    } else {
      // Plain — use ws:// with default port fallback
      let withPort = clean.contains(":") ? clean : "\(clean):\(defaultPort)"
      return URL(string: "ws://\(withPort)/ws")
    }
  }

  static func hostInput(from url: URL, defaultPort: Int) -> String? {
    guard let host = url.host else { return nil }
    let isSecure = url.scheme == "wss"
    if isSecure {
      if let port = url.port {
        return "https://\(host):\(port)"
      }
      return "https://\(host)"
    }
    if let port = url.port, port != defaultPort {
      return "\(host):\(port)"
    }
    return host
  }

  private static func normalizedToken(_ token: String?) -> String? {
    guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}

struct ServerEndpointTokenStore {
  private let serviceName = "com.orbitdock.server-endpoint-token"

  func token(for id: UUID) -> String? {
    token(forEndpointID: id.uuidString)
  }

  func token(forEndpointID endpointID: String) -> String? {
    var query = keychainQuery(forEndpointID: endpointID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func set(_ token: String?, for id: UUID) {
    set(token, forEndpointID: id.uuidString)
  }

  func set(_ token: String?, forEndpointID endpointID: String) {
    guard let token, let tokenData = token.data(using: .utf8) else {
      remove(forEndpointID: endpointID)
      return
    }

    let query = keychainQuery(forEndpointID: endpointID)
    let status = SecItemCopyMatching(query as CFDictionary, nil)

    if status == errSecSuccess {
      SecItemUpdate(query as CFDictionary, [kSecValueData as String: tokenData] as CFDictionary)
      return
    }

    if status == errSecItemNotFound {
      var addQuery = query
      addQuery[kSecValueData as String] = tokenData
      SecItemAdd(addQuery as CFDictionary, nil)
    }
  }

  func remove(forEndpointID endpointID: String) {
    SecItemDelete(keychainQuery(forEndpointID: endpointID) as CFDictionary)
  }

  private func keychainQuery(forEndpointID endpointID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: endpointID,
    ]
  }
}
