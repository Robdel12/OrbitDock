import Foundation

struct MissionSettings: Codable, Equatable {
  let provider: ProviderSettings
  let trigger: TriggerSettings
  let orchestration: OrchestrationSettings
  let promptTemplate: String
  let tracker: String

  enum CodingKeys: String, CodingKey {
    case provider, trigger, orchestration, tracker
    case promptTemplate = "prompt_template"
  }
}

struct ProviderSettings: Codable, Equatable {
  let strategy: String
  let primary: String
  let secondary: String?
  let maxConcurrent: UInt32
  let maxConcurrentPrimary: UInt32?

  enum CodingKeys: String, CodingKey {
    case strategy, primary, secondary
    case maxConcurrent = "max_concurrent"
    case maxConcurrentPrimary = "max_concurrent_primary"
  }
}

struct TriggerSettings: Codable, Equatable {
  let kind: String
  let interval: UInt64
  let filters: TriggerFilters
}

struct TriggerFilters: Codable, Equatable {
  let labels: [String]
  let states: [String]
  let project: String?
  let team: String?
}

struct OrchestrationSettings: Codable, Equatable {
  let maxRetries: UInt32
  let stallTimeout: UInt64
  let baseBranch: String

  enum CodingKeys: String, CodingKey {
    case maxRetries = "max_retries"
    case stallTimeout = "stall_timeout"
    case baseBranch = "base_branch"
  }
}
