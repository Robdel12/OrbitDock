import Foundation
import SwiftUI

struct MissionSummary: Codable, Identifiable, Equatable {
  let id: String
  let name: String
  let repoRoot: String
  let enabled: Bool
  let paused: Bool
  let trackerKind: String
  let provider: String
  let providerStrategy: String
  let primaryProvider: String
  let secondaryProvider: String?
  let activeCount: UInt32
  let queuedCount: UInt32
  let completedCount: UInt32
  let failedCount: UInt32
  let parseError: String?
  let orchestratorStatus: String?
  let lastPolledAt: String?
  let pollInterval: UInt64?

  enum CodingKeys: String, CodingKey {
    case id, name
    case repoRoot = "repo_root"
    case enabled
    case paused
    case trackerKind = "tracker_kind"
    case provider
    case providerStrategy = "provider_strategy"
    case primaryProvider = "primary_provider"
    case secondaryProvider = "secondary_provider"
    case activeCount = "active_count"
    case queuedCount = "queued_count"
    case completedCount = "completed_count"
    case failedCount = "failed_count"
    case parseError = "parse_error"
    case orchestratorStatus = "orchestrator_status"
    case lastPolledAt = "last_polled_at"
    case pollInterval = "poll_interval"
  }
}

extension MissionSummary {
  var statusLabel: String {
    if !enabled { return "Disabled" }
    if paused { return "Paused" }
    switch orchestratorStatus {
      case "polling": return "Polling"
      case "no_api_key": return "No API Key"
      case "config_error": return "Config Error"
      case "idle": return "Idle"
      default: return "Not Started"
    }
  }

  var statusColor: Color {
    if !enabled { return Color.textQuaternary }
    if paused { return Color.feedbackCaution }
    switch orchestratorStatus {
      case "polling": return Color.feedbackPositive
      case "no_api_key": return Color.feedbackCaution
      case "config_error": return Color.feedbackNegative
      default: return Color.textTertiary
    }
  }

  var repoName: String {
    repoRoot
      .split(separator: "/")
      .last
      .map(String.init) ?? repoRoot
  }

  var resolvedProvider: Provider {
    Provider(rawValue: primaryProvider) ?? .claude
  }
}
