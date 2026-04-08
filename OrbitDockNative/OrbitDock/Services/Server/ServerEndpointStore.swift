import Foundation
import os.log
import Security

struct ServerEndpointStore {
  static let endpointsStorageKey = "orbitdock.server.endpoints"
  static let endpointTokenIdsStorageKey = "orbitdock.server.endpoint-token-ids"
  static let endpointLocalPrefsStorageKey = "orbitdock.server.endpoint-local-prefs"

  private let defaults: UserDefaults
  private let endpointsKey: String
  private let endpointTokenIdsKey: String
  private let endpointLocalPrefsKey: String
  private let defaultPort: Int
  private let tokenStore: ServerEndpointTokenStore
  private let cloudSyncStore: ServerEndpointCloudSyncStore
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults = .standard,
    endpointsKey: String = ServerEndpointStore.endpointsStorageKey,
    endpointTokenIdsKey: String = ServerEndpointStore.endpointTokenIdsStorageKey,
    endpointLocalPrefsKey: String = ServerEndpointStore.endpointLocalPrefsStorageKey,
    tokenStore: ServerEndpointTokenStore = ServerEndpointTokenStore(),
    cloudSyncStore: ServerEndpointCloudSyncStore = .live(),
    defaultPort: Int = ServerEndpointSettings.defaultPort
  ) {
    self.defaults = defaults
    self.endpointsKey = endpointsKey
    self.endpointTokenIdsKey = endpointTokenIdsKey
    self.endpointLocalPrefsKey = endpointLocalPrefsKey
    self.tokenStore = tokenStore
    self.cloudSyncStore = cloudSyncStore
    self.defaultPort = defaultPort
  }

  func endpoints() -> [ServerEndpoint] {
    let localEndpoints = persistedEndpoints() ?? []
    let localPrefsById = persistedLocalPrefsByID()

    if let cloudRecords = cloudSyncStore.load() {
      let merged = mergedEndpoints(
        cloudRecords: cloudRecords,
        localEndpoints: localEndpoints,
        localPrefsById: localPrefsById
      )
      let normalized = normalizedEndpoints(merged)
      let hydrated = hydratedEndpoints(normalized)

      syncAuthTokens(from: hydrated)
      if normalized != localEndpoints || containsInlineAuthTokens(localEndpoints) {
        writeRedactedEndpointsToDefaults(normalized)
      }
      writeLocalPrefsToDefaults(normalized)
      cloudSyncStore.save(syncedRecords(from: normalized))
      return hydrated
    }

    guard !localEndpoints.isEmpty else {
      return []
    }

    let normalized = normalizedEndpoints(localEndpoints)
    let hydrated = hydratedEndpoints(normalized)
    syncAuthTokens(from: hydrated)

    if normalized != localEndpoints || containsInlineAuthTokens(localEndpoints) {
      writeRedactedEndpointsToDefaults(normalized)
    }
    writeLocalPrefsToDefaults(normalized)
    cloudSyncStore.save(syncedRecords(from: normalized))
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
    writeRedactedEndpointsToDefaults(normalized)
    writeLocalPrefsToDefaults(normalized)
    cloudSyncStore.save(syncedRecords(from: normalized))
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

  private func persistedLocalPrefsByID() -> [UUID: ServerEndpointLocalPrefs] {
    guard let data = defaults.data(forKey: endpointLocalPrefsKey), !data.isEmpty,
          let persisted = try? decoder.decode([ServerEndpointLocalPrefs].self, from: data)
    else {
      return [:]
    }

    var byID: [UUID: ServerEndpointLocalPrefs] = [:]
    for prefs in persisted {
      byID[prefs.id] = prefs
    }
    return byID
  }

  private func writeRedactedEndpointsToDefaults(_ endpoints: [ServerEndpoint]) {
    let redacted = redactedEndpoints(endpoints)
    guard let data = try? encoder.encode(redacted) else { return }
    defaults.set(data, forKey: endpointsKey)
  }

  private func writeLocalPrefsToDefaults(_ endpoints: [ServerEndpoint]) {
    let prefs = endpoints.map { endpoint in
      ServerEndpointLocalPrefs(
        id: endpoint.id,
        isEnabled: endpoint.isEnabled,
        isDefault: endpoint.isDefault
      )
    }
    guard let data = try? encoder.encode(prefs) else { return }
    defaults.set(data, forKey: endpointLocalPrefsKey)
  }

  private func redactedEndpoints(_ endpoints: [ServerEndpoint]) -> [ServerEndpoint] {
    endpoints.map { endpoint -> ServerEndpoint in
      var copy = endpoint
      copy.authToken = nil
      return copy
    }
  }

  private func syncedRecords(from endpoints: [ServerEndpoint]) -> [ServerEndpointCloudRecord] {
    endpoints.map { endpoint in
      ServerEndpointCloudRecord(
        id: endpoint.id,
        name: endpoint.name,
        wsURL: endpoint.wsURL,
        isEnabled: endpoint.isEnabled,
        isDefault: endpoint.isDefault
      )
    }
  }

  private func mergedEndpoints(
    cloudRecords: [ServerEndpointCloudRecord],
    localEndpoints: [ServerEndpoint],
    localPrefsById: [UUID: ServerEndpointLocalPrefs]
  ) -> [ServerEndpoint] {
    var localById: [UUID: ServerEndpoint] = [:]
    for endpoint in localEndpoints {
      localById[endpoint.id] = endpoint
    }

    var merged: [ServerEndpoint] = []
    var seen = Set<UUID>()

    for record in cloudRecords where seen.insert(record.id).inserted {
      let localEndpoint = localById[record.id]
      let localPrefs = localPrefsById[record.id]
      merged.append(
        ServerEndpoint(
          id: record.id,
          name: record.name,
          wsURL: record.wsURL,
          isEnabled: localPrefs?.isEnabled ?? localEndpoint?.isEnabled ?? record.isEnabled,
          isDefault: localPrefs?.isDefault ?? localEndpoint?.isDefault ?? record.isDefault,
          authToken: localEndpoint?.authToken
        )
      )
    }

    for endpoint in localEndpoints where seen.insert(endpoint.id).inserted {
      let localPrefs = localPrefsById[endpoint.id]
      var copy = endpoint
      if let localPrefs {
        copy.isEnabled = localPrefs.isEnabled
        copy.isDefault = localPrefs.isDefault
      }
      merged.append(copy)
    }

    return merged
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

  private func containsInlineAuthTokens(_ endpoints: [ServerEndpoint]) -> Bool {
    endpoints.contains { Self.normalizedToken($0.authToken) != nil }
  }
}

struct ServerEndpointLocalPrefs: Codable, Equatable {
  var id: UUID
  var isEnabled: Bool
  var isDefault: Bool
}

struct ServerEndpointCloudRecord: Codable, Equatable {
  var id: UUID
  var name: String
  var wsURL: URL
  var isEnabled: Bool
  var isDefault: Bool

  init(id: UUID, name: String, wsURL: URL, isEnabled: Bool = true, isDefault: Bool = false) {
    self.id = id
    self.name = name
    self.wsURL = wsURL
    self.isEnabled = isEnabled
    self.isDefault = isDefault
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case wsURL
    case isEnabled
    case isDefault
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    wsURL = try container.decode(URL.self, forKey: .wsURL)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(wsURL, forKey: .wsURL)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(isDefault, forKey: .isDefault)
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
    query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

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

    var updateQuery = keychainQuery(forEndpointID: endpointID)
    updateQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    let updateStatus = SecItemUpdate(
      updateQuery as CFDictionary,
      [kSecValueData as String: tokenData] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    if updateStatus != errSecItemNotFound {
      Self.logger.error("Keychain update failed: \(Int(updateStatus))")
      return
    }

    var addQuery = keychainQuery(forEndpointID: endpointID)
    addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
    addQuery[kSecValueData as String] = tokenData
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus != errSecSuccess {
      Self.logger.error("Keychain add failed: \(Int(addStatus))")
    }
  }

  func remove(forEndpointID endpointID: String) {
    var query = keychainQuery(forEndpointID: endpointID)
    query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    SecItemDelete(query as CFDictionary)
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

struct ServerEndpointCloudSyncStore {
  let load: () -> [ServerEndpointCloudRecord]?
  let save: ([ServerEndpointCloudRecord]) -> Void

  static func live() -> ServerEndpointCloudSyncStore {
    let keychain = ServerEndpointCloudSyncKeychain()
    return ServerEndpointCloudSyncStore(
      load: { keychain.load() },
      save: { keychain.save($0) }
    )
  }
}

private struct ServerEndpointCloudSyncKeychain {
  private static let logger = Logger(subsystem: "com.orbitdock", category: "keychain")
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let serviceName = "com.orbitdock.server-endpoints-sync"
  private let accountName = "endpoints-json-v1"

  func load() -> [ServerEndpointCloudRecord]? {
    var query = keychainQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      Self.logger.error("Synced endpoints read failed: \(Int(status))")
      return nil
    }
    return try? decoder.decode([ServerEndpointCloudRecord].self, from: data)
  }

  func save(_ endpoints: [ServerEndpointCloudRecord]) {
    guard let data = try? encoder.encode(endpoints) else { return }

    var updateQuery = keychainQuery
    updateQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    let updateStatus = SecItemUpdate(
      updateQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    if updateStatus != errSecItemNotFound {
      Self.logger.error("Synced endpoints update failed: \(Int(updateStatus))")
      return
    }

    var addQuery = keychainQuery
    addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
    addQuery[kSecValueData as String] = data
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus != errSecSuccess {
      Self.logger.error("Synced endpoints write failed: \(Int(addStatus))")
    }
  }

  private var keychainQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
    ]
  }
}
