import Foundation

enum OrbitDockProtocol {
  static let compatibility = "server_authoritative_session_v1"
  static let releaseVersion = "0.4.0"
  static let clientVersion = releaseVersion
}

enum ServerCompatibilityError: Error, Equatable, Sendable, LocalizedError {
  case incompatibleServer(
    serverVersion: String,
    serverCompatibility: String,
    reason: String?,
    message: String?
  )
  case missingCompatibilityMetadata(transport: String)
  case missingHelloHandshake(messageType: String)

  var errorDescription: String? {
    switch self {
      case let .incompatibleServer(serverVersion, serverCompatibility, _, message):
        message
          ?? "Server \(serverVersion) (\(serverCompatibility)) is not compatible with this app."
      case let .missingCompatibilityMetadata(transport):
        "Server \(transport) response did not include compatibility metadata."
      case let .missingHelloHandshake(messageType):
        "Server handshake failed: expected hello as the first WebSocket frame, received \(messageType)"
    }
  }
}

extension ServerCompatibilityError {
  var recoverySuggestion: String? {
    switch self {
      case let .incompatibleServer(_, _, reason, _):
        switch reason {
          case "upgrade_app":
            "Update OrbitDock to a build that matches the connected server."
          case "upgrade_server":
            "Update the OrbitDock server to match this app."
          default:
            "Run a compatible OrbitDock app and server pair."
        }
      case .missingCompatibilityMetadata:
        "Update the OrbitDock server so it can report compatibility cleanly."
      case .missingHelloHandshake:
        "Check that the server and client are running the same transport contract."
    }
  }
}

struct ServerCompatibilityStatus: Codable, Equatable, Sendable {
  let compatible: Bool
  let serverCompatibility: String
  let reason: String?
  let message: String?

  enum CodingKeys: String, CodingKey {
    case compatible
    case serverCompatibility = "server_compatibility"
    case reason
    case message
  }
}

extension ServerCompatibilityStatus {
  func validate(serverVersion: String) throws {
    guard compatible else {
      throw ServerCompatibilityError.incompatibleServer(
        serverVersion: serverVersion,
        serverCompatibility: serverCompatibility,
        reason: reason,
        message: message
      )
    }
  }
}

extension HTTPResponse {
  func validateServerCompatibilityHeaders() throws {
    guard let serverVersion = headerValue(for: "X-OrbitDock-Server-Version"),
          let serverCompatibility = headerValue(for: "X-OrbitDock-Server-Compatibility"),
          let rawCompatible = headerValue(for: "X-OrbitDock-Compatible")
    else {
      throw ServerCompatibilityError.missingCompatibilityMetadata(transport: "HTTP")
    }

    guard rawCompatible.caseInsensitiveCompare("true") == .orderedSame else {
      throw ServerCompatibilityError.incompatibleServer(
        serverVersion: serverVersion,
        serverCompatibility: serverCompatibility,
        reason: headerValue(for: "X-OrbitDock-Compatibility-Reason"),
        message: headerValue(for: "X-OrbitDock-Compatibility-Message")
      )
    }
  }
}

enum ServerSessionSurface: String, Codable, Sendable {
  case detail
  case composer
  case conversation
}

struct ServerHelloMetadata: Codable, Sendable {
  let serverVersion: String
  let compatibility: ServerCompatibilityStatus
  let capabilities: [String]

  enum CodingKeys: String, CodingKey {
    case serverVersion = "server_version"
    case compatibility
    case capabilities
  }

  func validateCompatibility() throws {
    try compatibility.validate(serverVersion: serverVersion)
  }
}

struct ServerMetaResponse: Codable, Sendable {
  let serverVersion: String
  let compatibility: ServerCompatibilityStatus
  let capabilities: [String]
  let isPrimary: Bool
  let clientPrimaryClaims: [ServerClientPrimaryClaim]
  let updateStatus: ServerUpdateStatus?

  enum CodingKeys: String, CodingKey {
    case serverVersion = "server_version"
    case compatibility
    case capabilities
    case isPrimary = "is_primary"
    case clientPrimaryClaims = "client_primary_claims"
    case updateStatus = "update_status"
  }

  init(
    serverVersion: String,
    compatibility: ServerCompatibilityStatus,
    capabilities: [String],
    isPrimary: Bool,
    clientPrimaryClaims: [ServerClientPrimaryClaim],
    updateStatus: ServerUpdateStatus? = nil
  ) {
    self.serverVersion = serverVersion
    self.compatibility = compatibility
    self.capabilities = capabilities
    self.isPrimary = isPrimary
    self.clientPrimaryClaims = clientPrimaryClaims
    self.updateStatus = updateStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    serverVersion = try container.decode(String.self, forKey: .serverVersion)
    compatibility = try container.decode(ServerCompatibilityStatus.self, forKey: .compatibility)
    capabilities = try container.decode([String].self, forKey: .capabilities)
    isPrimary = try container.decode(Bool.self, forKey: .isPrimary)
    clientPrimaryClaims =
      try container.decodeIfPresent([ServerClientPrimaryClaim].self, forKey: .clientPrimaryClaims)
      ?? []
    updateStatus = try container.decodeIfPresent(ServerUpdateStatus.self, forKey: .updateStatus)
  }

  func validateCompatibility() throws {
    try compatibility.validate(serverVersion: serverVersion)
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
