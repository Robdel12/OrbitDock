//
//  ServerWorktreeContracts.swift
//  OrbitDock
//
//  Worktree protocol contracts.
//

import Foundation

// MARK: - Worktree Types

enum ServerWorktreeStatus: String, Codable {
  case active
  case orphaned
  case stale
  case removing
  case removed
}

enum ServerWorktreeOrigin: String, Codable {
  case user
  case agent
  case discovered
}

struct ServerWorktreeSummary: Codable, Identifiable {
  var id: String
  var repoRoot: String
  var worktreePath: String
  var branch: String
  var baseBranch: String?
  var status: ServerWorktreeStatus
  var activeSessionCount: UInt32
  var totalSessionCount: UInt32
  var createdAt: String
  var lastSessionEndedAt: String?
  var diskPresent: Bool
  var autoPrune: Bool
  var customName: String?
  var createdBy: ServerWorktreeOrigin

  enum CodingKeys: String, CodingKey {
    case id, branch, status
    case repoRoot = "repo_root"
    case worktreePath = "worktree_path"
    case baseBranch = "base_branch"
    case activeSessionCount = "active_session_count"
    case totalSessionCount = "total_session_count"
    case createdAt = "created_at"
    case lastSessionEndedAt = "last_session_ended_at"
    case diskPresent = "disk_present"
    case autoPrune = "auto_prune"
    case customName = "custom_name"
    case createdBy = "created_by"
  }
}
