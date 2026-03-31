import Foundation

enum OrbitDockProtocol {
  static let releaseVersion: String = {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "0.0.0"
  }()
  static let clientVersion = releaseVersion
  static let minimumServerVersion: String = {
    Bundle.main.object(forInfoDictionaryKey: "OrbitDockMinimumServerVersion") as? String
      ?? clientVersion
  }()
}

private struct OrbitDockSemVer: Comparable, Sendable {
  let major: UInt64
  let minor: UInt64
  let patch: UInt64

  init?(_ string: String) {
    let parts = string.split(separator: ".", omittingEmptySubsequences: false)
    func parseComponent(_ component: Substring) -> UInt64? {
      let trimmed = component.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? component
      return UInt64(trimmed)
    }

    guard let majorPart = parts.first, let major = parseComponent(majorPart) else { return nil }
    let minor: UInt64
    if parts.count > 1 {
      guard let parsedMinor = parseComponent(parts[1]) else { return nil }
      minor = parsedMinor
    } else {
      minor = 0
    }
    let patchPart = parts.count > 2 ? parts[2] : "0"
    guard let patch = parseComponent(patchPart) else {
      return nil
    }
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    return lhs.patch < rhs.patch
  }
}

private func versionAtLeast(_ value: String, minimum: String) -> Bool {
  guard let lhs = OrbitDockSemVer(value), let rhs = OrbitDockSemVer(minimum) else {
    return false
  }
  return lhs >= rhs
}

enum ServerVersionError: Error, Equatable, Sendable, LocalizedError {
  case clientTooOld(clientVersion: String, minimumClientVersion: String)
  case serverTooOld(serverVersion: String, minimumServerVersion: String)
  case missingVersionMetadata(transport: String)
  case missingHelloHandshake(messageType: String)

  var errorDescription: String? {
    switch self {
      case let .clientTooOld(clientVersion, minimumClientVersion):
        "Update OrbitDock to version \(minimumClientVersion) or later (current: \(clientVersion))."
      case let .serverTooOld(serverVersion, minimumServerVersion):
        "Update the OrbitDock server to version \(minimumServerVersion) or later (current: \(serverVersion))."
      case let .missingVersionMetadata(transport):
        "Server \(transport) response did not include version metadata."
      case let .missingHelloHandshake(messageType):
        "Server handshake failed: expected hello as the first WebSocket frame, received \(messageType)"
    }
  }
}

extension ServerVersionError {
  var recoverySuggestion: String? {
    switch self {
      case .clientTooOld:
        "Update OrbitDock to a build that matches the connected server."
      case .serverTooOld:
        "Update the OrbitDock server to match this app."
      case .missingVersionMetadata:
        "Update the OrbitDock server so it can report version metadata cleanly."
      case .missingHelloHandshake:
        "Check that the server and client are running the same transport contract."
    }
  }
}

extension HTTPResponse {
  func validateServerVersionHeaders() throws {
    guard let serverVersion = headerValue(for: "X-OrbitDock-Server-Version"),
          let minimumClientVersion = headerValue(for: "X-OrbitDock-Minimum-Client-Version")
    else {
      // Legacy/proxied servers may omit version headers on HTTP.
      // When headers are absent we keep the request flow alive and rely on
      // WebSocket hello + /api/server/meta checks for compatibility diagnosis.
      return
    }

    try ServerVersionMetadata(
      serverVersion: serverVersion,
      minimumClientVersion: minimumClientVersion
    ).validate()
  }
}

enum ServerContractGuard {
  static func versionMessage(for error: Error, surface: String) -> String? {
    switch error {
      case let versionError as ServerVersionError:
        return userFacingMessage(for: versionError, surface: surface)
      case let requestError as ServerRequestError:
        switch requestError {
          case let .incompatibleServer(versionError):
            return userFacingMessage(for: versionError, surface: surface)
          default:
            return nil
        }
      case is DecodingError:
        return
          "OrbitDock couldn't read the server's \(surface) response. This usually means the server needs to be upgraded to match this app."
      default:
        return nil
    }
  }

  private static func userFacingMessage(
    for error: ServerVersionError,
    surface: String
  ) -> String {
    switch error {
      case .clientTooOld, .serverTooOld:
        return error.errorDescription
          ?? "This OrbitDock server is not compatible with the current app."
      case .missingVersionMetadata:
        return
          "OrbitDock couldn't verify server version metadata for \(surface). This usually means the server is too old for this app."
      case .missingHelloHandshake:
        return
          "OrbitDock couldn't complete the server version handshake. Make sure the server is upgraded to match this app."
    }
  }
}

struct ServerVersionMetadata: Codable, Equatable, Sendable {
  let serverVersion: String
  let minimumClientVersion: String

  enum CodingKeys: String, CodingKey {
    case serverVersion = "server_version"
    case minimumClientVersion = "minimum_client_version"
  }

  func validate() throws {
    if !versionAtLeast(serverVersion, minimum: OrbitDockProtocol.minimumServerVersion) {
      throw ServerVersionError.serverTooOld(
        serverVersion: serverVersion,
        minimumServerVersion: OrbitDockProtocol.minimumServerVersion
      )
    }

    if !versionAtLeast(OrbitDockProtocol.clientVersion, minimum: minimumClientVersion) {
      throw ServerVersionError.clientTooOld(
        clientVersion: OrbitDockProtocol.clientVersion,
        minimumClientVersion: minimumClientVersion
      )
    }
  }
}

enum ServerSessionSurface: String, Codable, CaseIterable, Sendable {
  case detail
  case composer
  case conversation
}

struct ServerHelloMetadata: Codable, Sendable {
  let serverVersion: String
  let minimumClientVersion: String
  let capabilities: [String]

  enum CodingKeys: String, CodingKey {
    case serverVersion = "server_version"
    case minimumClientVersion = "minimum_client_version"
    case capabilities
  }

  func validateCompatibility() throws {
    try ServerVersionMetadata(
      serverVersion: serverVersion,
      minimumClientVersion: minimumClientVersion
    ).validate()
  }
}

struct ServerMetaResponse: Codable, Sendable {
  let serverVersion: String
  let minimumClientVersion: String
  let capabilities: [String]
  let isPrimary: Bool
  let clientPrimaryClaims: [ServerClientPrimaryClaim]
  let updateStatus: ServerUpdateStatus?

  enum CodingKeys: String, CodingKey {
    case serverVersion = "server_version"
    case minimumClientVersion = "minimum_client_version"
    case capabilities
    case isPrimary = "is_primary"
    case clientPrimaryClaims = "client_primary_claims"
    case updateStatus = "update_status"
  }

  init(
    serverVersion: String,
    minimumClientVersion: String,
    capabilities: [String],
    isPrimary: Bool,
    clientPrimaryClaims: [ServerClientPrimaryClaim],
    updateStatus: ServerUpdateStatus? = nil
  ) {
    self.serverVersion = serverVersion
    self.minimumClientVersion = minimumClientVersion
    self.capabilities = capabilities
    self.isPrimary = isPrimary
    self.clientPrimaryClaims = clientPrimaryClaims
    self.updateStatus = updateStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    serverVersion = try container.decode(String.self, forKey: .serverVersion)
    minimumClientVersion = try container.decodeIfPresent(String.self, forKey: .minimumClientVersion)
      ?? OrbitDockProtocol.releaseVersion
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
    clientPrimaryClaims =
      try container.decodeIfPresent([ServerClientPrimaryClaim].self, forKey: .clientPrimaryClaims) ?? []
    updateStatus = try container.decodeIfPresent(ServerUpdateStatus.self, forKey: .updateStatus)
  }

  func validateCompatibility() throws {
    try ServerVersionMetadata(
      serverVersion: serverVersion,
      minimumClientVersion: minimumClientVersion
    ).validate()
  }
}

struct ServerDashboardCounts: Codable, Sendable {
  let attention: UInt32
  let running: UInt32
  let ready: UInt32
  let direct: UInt32
}

struct ServerDashboardSnapshotPayload: Codable, Sendable {
  let revision: UInt64
  let sessions: [ServerSessionListItem]
  let conversations: [ServerDashboardConversationItem]
  let counts: ServerDashboardCounts
}

struct ServerUsageSummaryModelCostPayload: Codable, Sendable {
  let model: String
  let costUSD: Double

  enum CodingKeys: String, CodingKey {
    case model
    case costUSD = "cost_usd"
  }
}

struct ServerUsageSummaryBucketPayload: Codable, Sendable {
  let sessionCount: UInt64
  let totalTokens: UInt64
  let inputTokens: UInt64
  let outputTokens: UInt64
  let cachedTokens: UInt64
  let totalCostUSD: Double
  let costByModel: [ServerUsageSummaryModelCostPayload]

  enum CodingKeys: String, CodingKey {
    case sessionCount = "session_count"
    case totalTokens = "total_tokens"
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cachedTokens = "cached_tokens"
    case totalCostUSD = "total_cost_usd"
    case costByModel = "cost_by_model"
  }
}

struct ServerUsageSummarySnapshotPayload: Codable, Sendable {
  let today: ServerUsageSummaryBucketPayload
  let allTime: ServerUsageSummaryBucketPayload

  enum CodingKeys: String, CodingKey {
    case today
    case allTime = "all_time"
  }
}

struct ServerMissionSnapshotPayload: Codable, Sendable {
  let revision: UInt64
  let missions: [MissionSummary]
}

struct ServerSessionDetailSnapshotPayload: Codable, Sendable {
  let revision: UInt64
  let session: ServerSessionState
}

struct ServerSessionComposerSnapshotPayload: Codable, Sendable {
  let revision: UInt64
  let session: ServerSessionState
}

struct ServerConversationSnapshotPayload: Codable, Sendable {
  let revision: UInt64
  let sessionId: String
  let session: ServerSessionState
  let rows: [ServerConversationRowEntry]
  let totalRowCount: UInt64
  let hasMoreBefore: Bool
  let oldestSequence: UInt64?
  let newestSequence: UInt64?

  enum CodingKeys: String, CodingKey {
    case revision
    case sessionId = "session_id"
    case session
    case rows
    case totalRowCount = "total_row_count"
    case hasMoreBefore = "has_more_before"
    case oldestSequence = "oldest_sequence"
    case newestSequence = "newest_sequence"
  }
}
