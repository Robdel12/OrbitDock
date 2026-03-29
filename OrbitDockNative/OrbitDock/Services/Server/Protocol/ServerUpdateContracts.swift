import Foundation

struct ServerUpdateStatus: Codable, Equatable, Sendable {
  let updateAvailable: Bool
  let latestVersion: String?
  let releaseURL: String?
  let channel: String
  let checkedAt: String?

  enum CodingKeys: String, CodingKey {
    case updateAvailable = "update_available"
    case latestVersion = "latest_version"
    case releaseURL = "release_url"
    case channel
    case checkedAt = "checked_at"
  }
}

struct ServerUpdateChannelResponse: Codable, Equatable, Sendable {
  let channel: String
}

struct ServerUpgradeStartResponse: Codable, Equatable, Sendable {
  let accepted: Bool
  let restartRequested: Bool
  let channel: String
  let targetVersion: String?
  let message: String

  enum CodingKeys: String, CodingKey {
    case accepted
    case restartRequested = "restart_requested"
    case channel
    case targetVersion = "target_version"
    case message
  }
}

struct ServerHealthResponse: Codable, Equatable, Sendable {
  let status: String
  let version: String?
}

struct ServerUpdateCheckResponse: Decodable, Equatable, Sendable {
  let status: ServerUpdateStatus?
  let error: String?

  private enum CodingKeys: String, CodingKey {
    case updateAvailable = "update_available"
    case latestVersion = "latest_version"
    case releaseURL = "release_url"
    case channel
    case checkedAt = "checked_at"
    case error
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let updateAvailable = try container.decodeIfPresent(Bool.self, forKey: .updateAvailable)
    let latestVersion = try container.decodeIfPresent(String.self, forKey: .latestVersion)
    let releaseURL = try container.decodeIfPresent(String.self, forKey: .releaseURL)
    let channel = try container.decodeIfPresent(String.self, forKey: .channel)
    let checkedAt = try container.decodeIfPresent(String.self, forKey: .checkedAt)

    if let updateAvailable, let channel {
      status = ServerUpdateStatus(
        updateAvailable: updateAvailable,
        latestVersion: latestVersion,
        releaseURL: releaseURL,
        channel: channel,
        checkedAt: checkedAt
      )
    } else {
      status = nil
    }

    error = try container.decodeIfPresent(String.self, forKey: .error)
  }
}
