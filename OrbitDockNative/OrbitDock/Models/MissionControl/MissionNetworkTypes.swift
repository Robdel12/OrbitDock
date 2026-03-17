import Foundation

struct MissionOkResponse: Decodable {
  let ok: Bool?
}

struct MissionUpdateBody: Encodable {
  let enabled: Bool?
  let paused: Bool?
}

struct EmptyBody: Encodable {}

struct MissionDetailResponse: Codable {
  let summary: MissionSummary
  let issues: [MissionIssueItem]
  let settings: MissionSettings?
  let missionFileExists: Bool
  let workflowMigrationAvailable: Bool

  enum CodingKeys: String, CodingKey {
    case summary, issues, settings
    case missionFileExists = "mission_file_exists"
    case workflowMigrationAvailable = "workflow_migration_available"
  }
}

struct MigrateResponse: Decodable {
  let summary: MissionSummary
}

struct SetLinearKeyBody: Encodable {
  let key: String
}

struct LinearKeyResponse: Decodable {
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
  let repoRoot: String
  let trackerKind: String
  let provider: String
}
