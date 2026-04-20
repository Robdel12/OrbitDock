import Foundation

struct MissionCleanupPrompt: Codable, Equatable {
  let lingeringWorktreeCount: UInt32

  enum CodingKeys: String, CodingKey {
    case lingeringWorktreeCount = "lingering_worktree_count"
  }
}

struct MissionOkResponse: Decodable {
  let ok: Bool?
}

struct MissionUpdateBody: Encodable {
  let name: String?
  let enabled: Bool?
  let paused: Bool?
}

struct EmptyBody: Encodable {}

struct MissionDetailResponse: Codable {
  let summary: MissionSummary
  let issues: [MissionIssueItem]
  let cleanupPrompt: MissionCleanupPrompt?
  let settings: MissionSettings?
  let missionFileExists: Bool
  let missionFilePath: String?

  enum CodingKeys: String, CodingKey {
    case summary, issues, settings
    case cleanupPrompt = "cleanup_prompt"
    case missionFileExists = "mission_file_exists"
    case missionFilePath = "mission_file_path"
  }
}

struct MigrateResponse: Decodable {
  let summary: MissionSummary
}

struct SetTrackerKeyBody: Encodable {
  let key: String
}

struct TrackerKeyResponse: Decodable {
  let configured: Bool
}

struct ScaffoldResponse: Codable {
  let summary: MissionSummary
  let issues: [MissionIssueItem]
  let settings: MissionSettings?
  let missionFileExists: Bool

  enum CodingKeys: String, CodingKey {
    case summary, issues, settings
    case missionFileExists = "mission_file_exists"
  }
}

struct MissionsListResponse: Codable {
  let missions: [MissionSummary]
}

struct CreateMissionRequest: Encodable {
  let name: String
  let repoRoot: String
  let trackerKind: String
  let provider: String
}
