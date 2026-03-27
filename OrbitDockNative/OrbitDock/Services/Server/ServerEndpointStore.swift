import Foundation
import os.log
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
      return []
    }

    let normalized = normalizedEndpoints(persisted)
    let hydrated = hydratedEndpoints(normalized)
    if normalized != persisted {
      save(hydrated)
    }
    return hydrated
  }

  func defaultEndpoint() -> ServerEndpoint {
    let current = endpoints()
    return current.first(where: { $0.isDefault && $0.isEnabled })
      ?? current.first(where: \.isEnabled)
      ?? ServerEndpoint(
        name: "Default Server",
        wsURL: URL(string: "ws://127.0.0.1:\(defaultPort)/ws")!,
        isEnabled: true,
        isDefault: true
      )
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

    save([
      ServerEndpoint(
        name: "Remote Server",
        wsURL: remoteURL,
        isEnabled: true,
        isDefault: true
      ),
    ])
  }

  func clearRemoteEndpoints() {
    save([])
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
    let currentIds = Set(endpoints.map(\.id.uuidString))
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
    var seen = Set<UUID>()
    endpoints = endpoints.filter { seen.insert($0.id).inserted }

    // Reconcile the default flag: pick the first enabled+default, or first enabled
    if let defaultIndex = endpoints.firstIndex(where: { $0.isDefault && $0.isEnabled })
      ?? endpoints.firstIndex(where: \.isEnabled)
    {
      for idx in endpoints.indices {
        endpoints[idx].isDefault = idx == defaultIndex
      }
    } else {
      // All disabled — clear all defaults
      for idx in endpoints.indices {
        endpoints[idx].isDefault = false
      }
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
    guard !isUnspecifiedBindAddress(clean) else { return nil }

    if forceSecure {
      // TLS — use wss://, no default port (443 is implicit)
      return URL(string: "wss://\(clean)/ws")
    } else {
      // Plain — use ws:// with default port fallback
      let withPort = clean.contains(":") ? clean : "\(clean):\(defaultPort)"
      return URL(string: "ws://\(withPort)/ws")
    }
  }

  private static func isUnspecifiedBindAddress(_ hostPort: String) -> Bool {
    let host = hostComponent(from: hostPort).lowercased()
    return host == "0.0.0.0" || host == "::"
  }

  private static func hostComponent(from hostPort: String) -> String {
    if hostPort.hasPrefix("["),
       let closingBracket = hostPort.firstIndex(of: "]")
    {
      return String(hostPort[hostPort.index(after: hostPort.startIndex) ..< closingBracket])
    }

    return hostPort.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPort
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
  private static let logger = Logger(subsystem: "com.orbitdock", category: "keychain")
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
    if status != errSecSuccess, status != errSecItemNotFound {
      Self.logger.error("Keychain read failed: \(Int(status))")
    }
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
      let updateStatus = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: tokenData] as CFDictionary
      )
      if updateStatus != errSecSuccess {
        Self.logger.error("Keychain update failed: \(Int(updateStatus))")
      }
      return
    }

    var addQuery = query
    addQuery[kSecValueData as String] = tokenData
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus != errSecSuccess {
      Self.logger.error("Keychain add failed: \(Int(addStatus))")
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
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
    ]
  }
}
