import Foundation
import os.log
import Security

/// Stores server endpoint configuration with iCloud sync.
///
/// **Synced via iCloud Keychain:**
/// - `id`, `name`, `wsURL`, `authToken`, `serverInstanceId`, `modifiedAt`
///
/// **Local-only (UserDefaults):**
/// - `isEnabled`, `isDefault`
///
/// This separation prevents iOS/macOS from fighting over enabled state.
struct ServerEndpointStore {
  static let endpointLocalPrefsStorageKey = "orbitdock.server.endpoint-local-prefs"
  static let lastCloudHashKey = "orbitdock.server.endpoints-cloud-hash"

  private let defaults: UserDefaults
  private let endpointLocalPrefsKey: String
  private let lastCloudHashKeyName: String
  private let defaultPort: Int
  private let cloudSyncStore: ServerEndpointCloudSyncStore
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private static let logger = Logger(subsystem: "com.orbitdock", category: "endpoint-store")

  init(
    defaults: UserDefaults = .standard,
    endpointLocalPrefsKey: String = ServerEndpointStore.endpointLocalPrefsStorageKey,
    lastCloudHashKey: String = ServerEndpointStore.lastCloudHashKey,
    cloudSyncStore: ServerEndpointCloudSyncStore = .live(),
    defaultPort: Int = ServerEndpointSettings.defaultPort
  ) {
    self.defaults = defaults
    self.endpointLocalPrefsKey = endpointLocalPrefsKey
    self.lastCloudHashKeyName = lastCloudHashKey
    self.cloudSyncStore = cloudSyncStore
    self.defaultPort = defaultPort
  }

  func endpoints() -> [ServerEndpoint] {
    let localPrefsById = persistedLocalPrefsByID()

    // Try cloud first
    if let cloudRecords = cloudSyncStore.load(), !cloudRecords.isEmpty {
      let endpoints = cloudRecords.map { record in
        let localPrefs = localPrefsById[record.id]
        return ServerEndpoint(
          id: record.id,
          name: record.name,
          wsURL: record.wsURL,
          isEnabled: localPrefs?.isEnabled ?? true,
          isDefault: localPrefs?.isDefault ?? false,
          authToken: record.authToken
        )
      }
      let serverInstanceIdByEndpointId = Dictionary(
        uniqueKeysWithValues: cloudRecords.map {
          ($0.id, Self.normalizedServerInstanceId($0.serverInstanceId))
        }
      )
      return normalizedEndpoints(
        endpoints,
        serverInstanceIdByEndpointId: serverInstanceIdByEndpointId
      )
    }

    return []
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
    let existingCloudRecords = cloudSyncStore.load() ?? []
    let existingCloudRecordsById = Dictionary(
      uniqueKeysWithValues: existingCloudRecords.map { ($0.id, $0) }
    )
    let normalized = normalizedEndpoints(
      rawEndpoints,
      serverInstanceIdByEndpointId: Dictionary(
        uniqueKeysWithValues: existingCloudRecords.map {
          ($0.id, Self.normalizedServerInstanceId($0.serverInstanceId))
        }
      )
    )
    let now = Date()

    // Build cloud records with current timestamp
    let cloudRecords = normalized.map { endpoint in
      ServerEndpointCloudRecord(
        id: endpoint.id,
        name: endpoint.name,
        wsURL: endpoint.wsURL,
        authToken: endpoint.authToken,
        serverInstanceId: existingCloudRecordsById[endpoint.id]?.serverInstanceId,
        modifiedAt: now
      )
    }

    // Only write to cloud if data actually changed
    let newHash = hashCloudRecords(cloudRecords)
    let previousHash = defaults.string(forKey: lastCloudHashKeyName)

    if newHash != previousHash {
      cloudSyncStore.save(cloudRecords)
      defaults.set(newHash, forKey: lastCloudHashKeyName)
      Self.logger.debug("Saved \(cloudRecords.count) endpoints to cloud sync")
    }

    // Always save local prefs
    writeLocalPrefsToDefaults(normalized)
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
    // Only update local prefs, not cloud (default is local-only)
    writeLocalPrefsToDefaults(updated)
  }

  func setEndpointEnabled(id: UUID, isEnabled: Bool) {
    var updated = endpoints()
    guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
    updated[index].isEnabled = isEnabled
    // Only update local prefs, not cloud (enabled is local-only)
    let normalized = normalizedEndpoints(updated)
    writeLocalPrefsToDefaults(normalized)
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

  func recordServerIdentity(id: UUID, serverInstanceId: String) {
    let normalizedServerInstanceId = Self.normalizedServerInstanceId(serverInstanceId)
    guard let normalizedServerInstanceId else { return }

    var cloudRecords = cloudSyncStore.load() ?? []
    guard let index = cloudRecords.firstIndex(where: { $0.id == id }) else { return }
    guard cloudRecords[index].serverInstanceId != normalizedServerInstanceId else { return }

    cloudRecords[index].serverInstanceId = normalizedServerInstanceId
    cloudRecords[index].modifiedAt = Date()
    cloudSyncStore.save(cloudRecords)
    defaults.set(hashCloudRecords(cloudRecords), forKey: lastCloudHashKeyName)
  }

  // MARK: - Private

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

  private func hashCloudRecords(_ records: [ServerEndpointCloudRecord]) -> String {
    // Hash based on durable synced fields, not timestamp, to avoid loops.
    let components = records.map {
      "\($0.id)|\($0.name)|\($0.wsURL)|\($0.authToken ?? "")|\($0.serverInstanceId ?? "")"
    }
    return components.sorted().joined(separator: ";")
  }

  private func normalizedEndpoints(
    _ rawEndpoints: [ServerEndpoint],
    serverInstanceIdByEndpointId: [UUID: String?] = [:]
  ) -> [ServerEndpoint] {
    var endpoints = rawEndpoints
    var seenIDs = Set<UUID>()
    endpoints = endpoints.filter { seenIDs.insert($0.id).inserted }

    var endpointsByIdentity: [String: ServerEndpoint] = [:]
    var identityOrder: [String] = []
    for endpoint in endpoints {
      let identity = serverInstanceIdByEndpointId[endpoint.id].flatMap { $0 }
        .map { "server:\($0)" }
        ?? "url:\(Self.endpointIdentity(for: endpoint.wsURL))"
      guard let existing = endpointsByIdentity[identity] else {
        endpointsByIdentity[identity] = endpoint
        identityOrder.append(identity)
        continue
      }

      let shouldReplace = Self.shouldPrefer(endpoint, over: existing)
      if shouldReplace {
        endpointsByIdentity[identity] = endpoint
      }
    }

    endpoints = identityOrder.compactMap { endpointsByIdentity[$0] }

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

  private static func endpointIdentity(for wsURL: URL) -> String {
    guard let components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
      return wsURL.absoluteString.lowercased()
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
    return "\(scheme)://\(host):\(port)\(path)\(query)"
  }

  private static func shouldPrefer(_ candidate: ServerEndpoint, over existing: ServerEndpoint) -> Bool {
    let candidateScore = endpointPreferenceScore(candidate)
    let existingScore = endpointPreferenceScore(existing)
    if candidateScore != existingScore {
      return candidateScore > existingScore
    }
    return candidate.id.uuidString < existing.id.uuidString
  }

  private static func endpointPreferenceScore(_ endpoint: ServerEndpoint) -> Int {
    var score = 0
    if endpoint.isDefault {
      score += 8
    }
    if endpoint.isEnabled {
      score += 4
    }
    if endpoint.isRemote {
      score += 2
    }
    return score
  }

  private static func normalizedServerInstanceId(_ serverInstanceId: String?) -> String? {
    guard let normalized = serverInstanceId?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !normalized.isEmpty
    else {
      return nil
    }
    return normalized
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
}

// MARK: - Supporting Types

struct ServerEndpointLocalPrefs: Codable, Equatable {
  var id: UUID
  var isEnabled: Bool
  var isDefault: Bool
}

/// Cloud-synced endpoint record.
/// Contains only the data that should sync across devices.
/// `isEnabled` and `isDefault` are intentionally NOT included — those are local-only.
struct ServerEndpointCloudRecord: Codable, Equatable {
  var id: UUID
  var name: String
  var wsURL: URL
  var authToken: String?
  var serverInstanceId: String?
  var modifiedAt: Date

  init(
    id: UUID,
    name: String,
    wsURL: URL,
    authToken: String? = nil,
    serverInstanceId: String? = nil,
    modifiedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.wsURL = wsURL
    self.authToken = authToken
    self.serverInstanceId = serverInstanceId
    self.modifiedAt = modifiedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case wsURL
    case authToken
    case serverInstanceId = "server_instance_id"
    case modifiedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    wsURL = try container.decode(URL.self, forKey: .wsURL)
    authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
    serverInstanceId = try container.decodeIfPresent(String.self, forKey: .serverInstanceId)
    modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date.distantPast
  }
}

// MARK: - Cloud Sync Store

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
  private let accountNameV2 = "endpoints-json-v2"

  func load() -> [ServerEndpointCloudRecord]? {
    if let v2Data = loadFromKeychain(accountName: accountNameV2),
       let records = try? decoder.decode([ServerEndpointCloudRecord].self, from: v2Data)
    {
      return records
    }
    return nil
  }

  func save(_ endpoints: [ServerEndpointCloudRecord]) {
    guard let data = try? encoder.encode(endpoints) else { return }

    var updateQuery = keychainQuery(accountName: accountNameV2)
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

    var addQuery = keychainQuery(accountName: accountNameV2)
    addQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue
    addQuery[kSecValueData as String] = data
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus != errSecSuccess {
      Self.logger.error("Synced endpoints write failed: \(Int(addStatus))")
    }
  }

  // MARK: - Keychain Helpers

  private func loadFromKeychain(accountName: String) -> Data? {
    var query = keychainQuery(accountName: accountName)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      Self.logger.error("Keychain read failed for \(accountName): \(Int(status))")
      return nil
    }
    return data
  }

  private func deleteFromKeychain(accountName: String) {
    var query = keychainQuery(accountName: accountName)
    query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    SecItemDelete(query as CFDictionary)
  }

  private func keychainQuery(accountName: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
    ]
  }
}
