import Foundation

struct MissionSummary: Codable, Identifiable, Equatable {
  let id: String
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

  enum CodingKeys: String, CodingKey {
    case id
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
  }
}
