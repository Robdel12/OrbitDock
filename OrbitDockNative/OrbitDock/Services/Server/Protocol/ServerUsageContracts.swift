//
//  ServerUsageContracts.swift
//  OrbitDock
//
//  Usage and rate-limit protocol contracts.
//

import Foundation

// MARK: - Rate Limit Info

struct ServerRateLimitInfo: Codable {
  let status: String
  let resetsAt: String?
  let rateLimitType: String?
  let utilization: Double?
  let isUsingOverage: Bool?
  let overageStatus: String?
  let surpassedThreshold: Double?

  enum CodingKeys: String, CodingKey {
    case status
    case resetsAt = "resets_at"
    case rateLimitType = "rate_limit_type"
    case utilization
    case isUsingOverage = "is_using_overage"
    case overageStatus = "overage_status"
    case surpassedThreshold = "surpassed_threshold"
  }

  var isWarning: Bool {
    status == "allowed_warning"
  }

  var isRejected: Bool {
    status == "rejected"
  }

  var needsDisplay: Bool {
    status != "allowed"
  }
}

struct ServerUsageErrorInfo: Codable {
  let code: String
  let message: String
}

struct ServerClientPrimaryClaim: Codable, Equatable, Identifiable {
  let clientId: String
  let deviceName: String

  var id: String {
    clientId
  }

  enum CodingKeys: String, CodingKey {
    case clientId = "client_id"
    case deviceName = "device_name"
  }
}

struct ServerCodexRateLimitWindow: Codable {
  let usedPercent: Double
  let windowDurationMins: UInt32
  let resetsAtUnix: Double

  enum CodingKeys: String, CodingKey {
    case usedPercent = "used_percent"
    case windowDurationMins = "window_duration_mins"
    case resetsAtUnix = "resets_at_unix"
  }
}

struct ServerCodexUsageSnapshot: Codable {
  let primary: ServerCodexRateLimitWindow?
  let secondary: ServerCodexRateLimitWindow?
  let fetchedAtUnix: Double

  enum CodingKeys: String, CodingKey {
    case primary
    case secondary
    case fetchedAtUnix = "fetched_at_unix"
  }
}

struct ServerClaudeUsageWindow: Codable {
  let utilization: Double
  let resetsAt: String?

  enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }
}

struct ServerClaudeUsageSnapshot: Codable {
  let fiveHour: ServerClaudeUsageWindow
  let sevenDay: ServerClaudeUsageWindow?
  let sevenDaySonnet: ServerClaudeUsageWindow?
  let sevenDayOpus: ServerClaudeUsageWindow?
  let rateLimitTier: String?
  let fetchedAtUnix: Double

  enum CodingKeys: String, CodingKey {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case sevenDaySonnet = "seven_day_sonnet"
    case sevenDayOpus = "seven_day_opus"
    case rateLimitTier = "rate_limit_tier"
    case fetchedAtUnix = "fetched_at_unix"
  }
}
