import Foundation

private let fallbackServerMetaMinimumClientVersion = Bundle.main.object(
  forInfoDictionaryKey: "CFBundleShortVersionString"
) as? String ?? "0.0.0"

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
      ?? fallbackServerMetaMinimumClientVersion
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
    clientPrimaryClaims =
      try container.decodeIfPresent([ServerClientPrimaryClaim].self, forKey: .clientPrimaryClaims) ?? []
    updateStatus = try container.decodeIfPresent(ServerUpdateStatus.self, forKey: .updateStatus)
  }
}
