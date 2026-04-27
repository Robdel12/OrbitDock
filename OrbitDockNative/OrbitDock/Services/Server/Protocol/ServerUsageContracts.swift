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

enum ServerCodexRateLimitReachedType: String, Codable {
  case rateLimitReached = "rate_limit_reached"
  case workspaceOwnerCreditsDepleted = "workspace_owner_credits_depleted"
  case workspaceMemberCreditsDepleted = "workspace_member_credits_depleted"
  case workspaceOwnerUsageLimitReached = "workspace_owner_usage_limit_reached"
  case workspaceMemberUsageLimitReached = "workspace_member_usage_limit_reached"
}

struct ServerCodexUsageSnapshot: Codable {
  let primary: ServerCodexRateLimitWindow?
  let secondary: ServerCodexRateLimitWindow?
  let rateLimitReachedType: ServerCodexRateLimitReachedType?
  let fetchedAtUnix: Double

  enum CodingKeys: String, CodingKey {
    case primary
    case secondary
    case rateLimitReachedType = "rate_limit_reached_type"
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

enum ServerUsageBreakdownGroupBy: String, Codable, Sendable {
  case provider
  case model
  case session
  case day
}

struct ServerUsageBreakdownEntryPayload: Codable, Sendable {
  let groupKey: String
  let provider: ServerProvider?
  let model: String?
  let sessionId: String?
  let dayStartUnix: UInt64?
  let turnCount: UInt64
  let sessionCount: UInt64
  let distinctSessionCount: UInt64
  let inputTokens: UInt64
  let outputTokens: UInt64
  let cachedTokens: UInt64
  let totalTokens: UInt64
  let totalCostUSD: Double

  enum CodingKeys: String, CodingKey {
    case groupKey = "group_key"
    case provider
    case model
    case sessionId = "session_id"
    case dayStartUnix = "day_start_unix"
    case turnCount = "turn_count"
    case sessionCount = "session_count"
    case distinctSessionCount = "distinct_session_count"
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cachedTokens = "cached_tokens"
    case totalTokens = "total_tokens"
    case totalCostUSD = "total_cost_usd"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    groupKey = try container.decode(String.self, forKey: .groupKey)
    provider = try container.decodeIfPresent(ServerProvider.self, forKey: .provider)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    dayStartUnix = try container.decodeIfPresent(UInt64.self, forKey: .dayStartUnix)
    turnCount = try container.decode(UInt64.self, forKey: .turnCount)
    sessionCount = try container.decode(UInt64.self, forKey: .sessionCount)
    distinctSessionCount = try container.decodeIfPresent(UInt64.self, forKey: .distinctSessionCount)
      ?? sessionCount
    inputTokens = try container.decode(UInt64.self, forKey: .inputTokens)
    outputTokens = try container.decode(UInt64.self, forKey: .outputTokens)
    cachedTokens = try container.decode(UInt64.self, forKey: .cachedTokens)
    totalTokens = try container.decode(UInt64.self, forKey: .totalTokens)
    totalCostUSD = try container.decode(Double.self, forKey: .totalCostUSD)
  }

  init(
    groupKey: String,
    provider: ServerProvider?,
    model: String?,
    sessionId: String?,
    dayStartUnix: UInt64?,
    turnCount: UInt64,
    sessionCount: UInt64,
    distinctSessionCount: UInt64,
    inputTokens: UInt64,
    outputTokens: UInt64,
    cachedTokens: UInt64,
    totalTokens: UInt64,
    totalCostUSD: Double
  ) {
    self.groupKey = groupKey
    self.provider = provider
    self.model = model
    self.sessionId = sessionId
    self.dayStartUnix = dayStartUnix
    self.turnCount = turnCount
    self.sessionCount = sessionCount
    self.distinctSessionCount = distinctSessionCount
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedTokens = cachedTokens
    self.totalTokens = totalTokens
    self.totalCostUSD = totalCostUSD
  }
}

struct ServerUsageBreakdownSnapshotPayload: Codable, Sendable {
  let groupBy: ServerUsageBreakdownGroupBy
  let startUnix: UInt64?
  let endUnix: UInt64?
  let totals: ServerUsageSummaryBucketPayload
  let groups: [ServerUsageBreakdownEntryPayload]

  enum CodingKeys: String, CodingKey {
    case groupBy = "group_by"
    case startUnix = "start_unix"
    case endUnix = "end_unix"
    case totals
    case groups
  }
}

struct ServerUsagePricingSnapshotPayload: Codable, Sendable {
  let source: String
  let version: String
  let modelKey: String?
  let inputCostPerToken: Double
  let outputCostPerToken: Double
  let cacheReadCostPerToken: Double
  let cacheWriteCostPerToken: Double

  enum CodingKeys: String, CodingKey {
    case source
    case version
    case modelKey = "model_key"
    case inputCostPerToken = "input_cost_per_token"
    case outputCostPerToken = "output_cost_per_token"
    case cacheReadCostPerToken = "cache_read_cost_per_token"
    case cacheWriteCostPerToken = "cache_write_cost_per_token"
  }
}

struct ServerSessionUsageTurnEntryPayload: Codable, Sendable {
  let turnId: String
  let turnSeq: UInt64
  let provider: ServerProvider
  let model: String?
  let observedAt: String?
  let snapshotKind: ServerTokenUsageSnapshotKind
  let rawUsage: ServerTokenUsage
  let billableInputTokens: UInt64
  let billableOutputTokens: UInt64
  let cacheReadTokens: UInt64
  let cacheWriteTokens: UInt64
  let contextInputTokens: UInt64
  let estimatedCostUSD: Double
  let pricing: ServerUsagePricingSnapshotPayload

  enum CodingKeys: String, CodingKey {
    case turnId = "turn_id"
    case turnSeq = "turn_seq"
    case provider
    case model
    case observedAt = "observed_at"
    case snapshotKind = "snapshot_kind"
    case rawUsage = "raw_usage"
    case billableInputTokens = "billable_input_tokens"
    case billableOutputTokens = "billable_output_tokens"
    case cacheReadTokens = "cache_read_tokens"
    case cacheWriteTokens = "cache_write_tokens"
    case contextInputTokens = "context_input_tokens"
    case estimatedCostUSD = "estimated_cost_usd"
    case pricing
  }
}

struct ServerSessionUsageTurnsPagePayload: Codable, Sendable {
  let sessionId: String
  let totalTurnCount: UInt64
  let hasMoreBefore: Bool
  let oldestTurnSeq: UInt64?
  let newestTurnSeq: UInt64?
  let summary: ServerUsageSummaryBucketPayload
  let rows: [ServerSessionUsageTurnEntryPayload]

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case totalTurnCount = "total_turn_count"
    case hasMoreBefore = "has_more_before"
    case oldestTurnSeq = "oldest_turn_seq"
    case newestTurnSeq = "newest_turn_seq"
    case summary
    case rows
  }
}

struct ServerUsageOverviewSnapshotPayload: Codable, Sendable {
  let todayStartUnix: UInt64?
  let summary: ServerUsageSummarySnapshotPayload
  let todayProviderBreakdown: ServerUsageBreakdownSnapshotPayload
  let todayModelBreakdown: ServerUsageBreakdownSnapshotPayload
  let dayBreakdown: ServerUsageBreakdownSnapshotPayload

  enum CodingKeys: String, CodingKey {
    case todayStartUnix = "today_start_unix"
    case summary
    case todayProviderBreakdown = "today_provider_breakdown"
    case todayModelBreakdown = "today_model_breakdown"
    case dayBreakdown = "day_breakdown"
  }
}

struct ServerUsageSessionSummaryPayload: Codable, Identifiable, Sendable {
  let sessionId: String
  let provider: ServerProvider
  let displayName: String
  let projectName: String?
  let projectPath: String
  let model: String?
  let startedAt: String?
  let lastActivityAt: String?
  let contextLine: String?
  let turnCount: UInt64
  let inputTokens: UInt64
  let outputTokens: UInt64
  let cachedTokens: UInt64
  let totalTokens: UInt64
  let totalCostUSD: Double

  var id: String {
    sessionId
  }

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case provider
    case displayName = "display_name"
    case projectName = "project_name"
    case projectPath = "project_path"
    case model
    case startedAt = "started_at"
    case lastActivityAt = "last_activity_at"
    case contextLine = "context_line"
    case turnCount = "turn_count"
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cachedTokens = "cached_tokens"
    case totalTokens = "total_tokens"
    case totalCostUSD = "total_cost_usd"
  }
}

struct ServerUsageSessionsSnapshotPayload: Codable, Sendable {
  let startUnix: UInt64?
  let endUnix: UInt64?
  let nextOffset: UInt64?
  let totalCount: UInt64
  let sessions: [ServerUsageSessionSummaryPayload]

  enum CodingKeys: String, CodingKey {
    case startUnix = "start_unix"
    case endUnix = "end_unix"
    case nextOffset = "next_offset"
    case totalCount = "total_count"
    case sessions
  }
}
