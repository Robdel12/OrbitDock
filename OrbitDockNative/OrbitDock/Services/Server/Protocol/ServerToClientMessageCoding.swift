//
//  ServerToClientMessageCoding.swift
//  OrbitDock
//
//  Shared coding keys for server-to-client messages.
//

import Foundation

extension ServerToClientMessage {
  enum CodingKeys: String, CodingKey {
    case type
    case sessions
    case session
    case conversation
    case sessionId = "session_id"
    case changes
    case message
    case messageId = "message_id"
    case upserted
    case removedRowIds = "removed_row_ids"
    case totalRowCount = "total_row_count"
    case request
    case usage
    case reason
    case code
    case error
    case errorInfo = "error_info"
    case approvals
    case approvalId = "approval_id"
    case models
    case loginId = "login_id"
    case authUrl = "auth_url"
    case skills
    case errors
    case id
    case name
    case path
    case success
    case numTurns = "num_turns"
    case tools
    case resources
    case resourceTemplates = "resource_templates"
    case authStatuses = "auth_statuses"
    case server
    case status
    case ready
    case failed
    case cancelled
    case sourceSessionId = "source_session_id"
    case newSessionId = "new_session_id"
    case forkedFromThreadId = "forked_from_thread_id"
    case turnId = "turn_id"
    case diff
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cachedTokens = "cached_tokens"
    case contextWindow = "context_window"
    case snapshotKind = "snapshot_kind"
    case comment
    case commentId = "comment_id"
    case comments
    case subagentId = "subagent_id"
    case requestId = "request_id"
    case command
    case stdout
    case stderr
    case exitCode = "exit_code"
    case durationMs = "duration_ms"
    case slashCommands = "slash_commands"
    case entries
    case projects
    case configured
    case isPrimary = "is_primary"
    case clientPrimaryClaims = "client_primary_claims"
    case approvalVersion = "approval_version"
    case outcome
    case activeRequestId = "active_request_id"
    case worktrees
    case worktree
    case worktreeId = "worktree_id"
    case repoRoot = "repo_root"
    case force
    case info
    case suggestion
    case files
    case worktreeRevision = "worktree_revision"
    case reviewRevision = "review_revision"
    case rules
    case missions
    case missionId = "mission_id"
    case issues
    case summary
  }
}
