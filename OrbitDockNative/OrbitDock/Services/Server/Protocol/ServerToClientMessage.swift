//
//  ServerToClientMessage.swift
//  OrbitDock
//
//  Server-to-client WebSocket message contracts.
//

import Foundation

// MARK: - Server → Client Messages

enum ServerToClientMessage: Codable {
  case sessionsList(sessions: [ServerSessionSummary])
  case sessionSnapshot(session: ServerSessionState)
  case sessionDelta(sessionId: String, changes: ServerStateChanges)
  case messageAppended(sessionId: String, message: ServerMessage)
  case messageUpdated(sessionId: String, messageId: String, changes: ServerMessageChanges)
  case approvalRequested(sessionId: String, request: ServerApprovalRequest, approvalVersion: UInt64?)
  case tokensUpdated(sessionId: String, usage: ServerTokenUsage, snapshotKind: ServerTokenUsageSnapshotKind)
  case sessionCreated(session: ServerSessionSummary)
  case sessionEnded(sessionId: String, reason: String)
  case approvalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem])
  case approvalDeleted(approvalId: Int64)
  case modelsList(models: [ServerCodexModelOption])
  case codexAccountStatus(status: ServerCodexAccountStatus)
  case codexLoginChatgptStarted(loginId: String, authUrl: String)
  case codexLoginChatgptCompleted(loginId: String, success: Bool, error: String?)
  case codexLoginChatgptCanceled(loginId: String, status: ServerCodexLoginCancelStatus)
  case codexAccountUpdated(status: ServerCodexAccountStatus)
  case skillsList(sessionId: String, skills: [ServerSkillsListEntry], errors: [ServerSkillErrorInfo])
  case remoteSkillsList(sessionId: String, skills: [ServerRemoteSkillSummary])
  case remoteSkillDownloaded(sessionId: String, skillId: String, name: String, path: String)
  case skillsUpdateAvailable(sessionId: String)
  case mcpToolsList(
    sessionId: String,
    tools: [String: ServerMcpTool],
    resources: [String: [ServerMcpResource]],
    resourceTemplates: [String: [ServerMcpResourceTemplate]],
    authStatuses: [String: ServerMcpAuthStatus]
  )
  case mcpStartupUpdate(sessionId: String, server: String, status: ServerMcpStartupStatus)
  case mcpStartupComplete(sessionId: String, ready: [String], failed: [ServerMcpStartupFailure], cancelled: [String])
  case claudeCapabilities(
    sessionId: String,
    slashCommands: [String],
    skills: [String],
    tools: [String],
    models: [ServerClaudeModelOption]
  )
  case claudeModelsList(models: [ServerClaudeModelOption])
  case contextCompacted(sessionId: String)
  case undoStarted(sessionId: String, message: String?)
  case undoCompleted(sessionId: String, success: Bool, message: String?)
  case threadRolledBack(sessionId: String, numTurns: UInt32)
  case sessionForked(sourceSessionId: String, newSessionId: String, forkedFromThreadId: String?)
  case turnDiffSnapshot(
    sessionId: String,
    turnId: String,
    diff: String,
    inputTokens: UInt64?,
    outputTokens: UInt64?,
    cachedTokens: UInt64?,
    contextWindow: UInt64?,
    snapshotKind: ServerTokenUsageSnapshotKind
  )
  case reviewCommentCreated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentUpdated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentDeleted(sessionId: String, reviewRevision: UInt64, commentId: String)
  case reviewCommentsList(sessionId: String, reviewRevision: UInt64, comments: [ServerReviewComment])
  case subagentToolsList(sessionId: String, subagentId: String, tools: [ServerSubagentTool])
  case shellStarted(sessionId: String, requestId: String, command: String)
  case shellOutput(
    sessionId: String,
    requestId: String,
    stdout: String,
    stderr: String,
    exitCode: Int32?,
    durationMs: UInt64,
    outcome: ServerShellExecutionOutcome
  )
  case directoryListing(requestId: String, path: String, entries: [ServerDirectoryEntry])
  case recentProjectsList(requestId: String, projects: [ServerRecentProject])
  case codexUsageResult(requestId: String, usage: ServerCodexUsageSnapshot?, errorInfo: ServerUsageErrorInfo?)
  case claudeUsageResult(requestId: String, usage: ServerClaudeUsageSnapshot?, errorInfo: ServerUsageErrorInfo?)
  case openAiKeyStatus(requestId: String, configured: Bool)
  case serverInfo(isPrimary: Bool, clientPrimaryClaims: [ServerClientPrimaryClaim])
  case approvalDecisionResult(
    sessionId: String,
    requestId: String,
    outcome: String,
    activeRequestId: String?,
    approvalVersion: UInt64
  )
  case worktreesList(requestId: String, repoRoot: String?, worktreeRevision: UInt64, worktrees: [ServerWorktreeSummary])
  case worktreeCreated(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktree: ServerWorktreeSummary)
  case worktreeRemoved(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktreeId: String)
  case worktreeStatusChanged(worktreeId: String, status: ServerWorktreeStatus, repoRoot: String)
  case worktreeError(requestId: String, code: String, message: String)
  case rateLimitEvent(sessionId: String, info: ServerRateLimitInfo)
  case promptSuggestion(sessionId: String, suggestion: String)
  case filesPersisted(sessionId: String, files: [String])
  case permissionRules(sessionId: String, rules: ServerSessionPermissionRules)
  case error(code: String, message: String, sessionId: String?)

  enum CodingKeys: String, CodingKey {
    case type
    case sessions
    case session
    case sessionId = "session_id"
    case changes
    case message
    case messageId = "message_id"
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
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
      case "sessions_list":
        let sessions = try container.decode([ServerSessionSummary].self, forKey: .sessions)
        self = .sessionsList(sessions: sessions)

      case "session_snapshot":
        let session = try container.decode(ServerSessionState.self, forKey: .session)
        self = .sessionSnapshot(session: session)

      case "session_delta":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let changes = try container.decode(ServerStateChanges.self, forKey: .changes)
        self = .sessionDelta(sessionId: sessionId, changes: changes)

      case "message_appended":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let message = try container.decode(ServerMessage.self, forKey: .message)
        self = .messageAppended(sessionId: sessionId, message: message)

      case "message_updated":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let messageId = try container.decode(String.self, forKey: .messageId)
        let changes = try container.decode(ServerMessageChanges.self, forKey: .changes)
        self = .messageUpdated(sessionId: sessionId, messageId: messageId, changes: changes)

      case "approval_requested":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let request = try container.decode(ServerApprovalRequest.self, forKey: .request)
        let approvalVersion = try container.decodeIfPresent(UInt64.self, forKey: .approvalVersion)
        self = .approvalRequested(sessionId: sessionId, request: request, approvalVersion: approvalVersion)

      case "tokens_updated":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let usage = try container.decode(ServerTokenUsage.self, forKey: .usage)
        let snapshotKind =
          try container.decodeIfPresent(ServerTokenUsageSnapshotKind.self, forKey: .snapshotKind) ?? .unknown
        self = .tokensUpdated(sessionId: sessionId, usage: usage, snapshotKind: snapshotKind)

      case "session_created":
        let session = try container.decode(ServerSessionSummary.self, forKey: .session)
        self = .sessionCreated(session: session)

      case "session_ended":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let reason = try container.decode(String.self, forKey: .reason)
        self = .sessionEnded(sessionId: sessionId, reason: reason)

      case "approvals_list":
        let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        let approvals = try container.decode([ServerApprovalHistoryItem].self, forKey: .approvals)
        self = .approvalsList(sessionId: sessionId, approvals: approvals)

      case "approval_deleted":
        let approvalId = try container.decode(Int64.self, forKey: .approvalId)
        self = .approvalDeleted(approvalId: approvalId)

      case "models_list":
        let models = try container.decode([ServerCodexModelOption].self, forKey: .models)
        self = .modelsList(models: models)

      case "codex_account_status":
        let status = try container.decode(ServerCodexAccountStatus.self, forKey: .status)
        self = .codexAccountStatus(status: status)

      case "codex_login_chatgpt_started":
        let loginId = try container.decode(String.self, forKey: .loginId)
        let authUrl = try container.decode(String.self, forKey: .authUrl)
        self = .codexLoginChatgptStarted(loginId: loginId, authUrl: authUrl)

      case "codex_login_chatgpt_completed":
        let loginId = try container.decode(String.self, forKey: .loginId)
        let success = try container.decode(Bool.self, forKey: .success)
        let error = try container.decodeIfPresent(String.self, forKey: .error)
        self = .codexLoginChatgptCompleted(loginId: loginId, success: success, error: error)

      case "codex_login_chatgpt_canceled":
        let loginId = try container.decode(String.self, forKey: .loginId)
        let status = try container.decode(ServerCodexLoginCancelStatus.self, forKey: .status)
        self = .codexLoginChatgptCanceled(loginId: loginId, status: status)

      case "codex_account_updated":
        let status = try container.decode(ServerCodexAccountStatus.self, forKey: .status)
        self = .codexAccountUpdated(status: status)

      case "skills_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let skills = try container.decode([ServerSkillsListEntry].self, forKey: .skills)
        let errors = try container.decodeIfPresent([ServerSkillErrorInfo].self, forKey: .errors) ?? []
        self = .skillsList(sessionId: sessionId, skills: skills, errors: errors)

      case "remote_skills_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let skills = try container.decode([ServerRemoteSkillSummary].self, forKey: .skills)
        self = .remoteSkillsList(sessionId: sessionId, skills: skills)

      case "remote_skill_downloaded":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let path = try container.decode(String.self, forKey: .path)
        self = .remoteSkillDownloaded(sessionId: sessionId, skillId: id, name: name, path: path)

      case "skills_update_available":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        self = .skillsUpdateAvailable(sessionId: sessionId)

      case "mcp_tools_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let tools = try container.decode([String: ServerMcpTool].self, forKey: .tools)
        let resources = try container.decode([String: [ServerMcpResource]].self, forKey: .resources)
        let resourceTemplates = try container.decode(
          [String: [ServerMcpResourceTemplate]].self,
          forKey: .resourceTemplates
        )
        let authStatuses = try container.decode([String: ServerMcpAuthStatus].self, forKey: .authStatuses)
        self = .mcpToolsList(
          sessionId: sessionId,
          tools: tools,
          resources: resources,
          resourceTemplates: resourceTemplates,
          authStatuses: authStatuses
        )

      case "mcp_startup_update":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let server = try container.decode(String.self, forKey: .server)
        let status = try container.decode(ServerMcpStartupStatus.self, forKey: .status)
        self = .mcpStartupUpdate(sessionId: sessionId, server: server, status: status)

      case "mcp_startup_complete":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let ready = try container.decode([String].self, forKey: .ready)
        let failed = try container.decode([ServerMcpStartupFailure].self, forKey: .failed)
        let cancelled = try container.decode([String].self, forKey: .cancelled)
        self = .mcpStartupComplete(sessionId: sessionId, ready: ready, failed: failed, cancelled: cancelled)

      case "claude_capabilities":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let slashCommands = try container.decodeIfPresent([String].self, forKey: .slashCommands) ?? []
        let skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        let tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        let models = try container.decodeIfPresent([ServerClaudeModelOption].self, forKey: .models) ?? []
        self = .claudeCapabilities(
          sessionId: sessionId,
          slashCommands: slashCommands,
          skills: skills,
          tools: tools,
          models: models
        )

      case "claude_models_list":
        let models = try container.decode([ServerClaudeModelOption].self, forKey: .models)
        self = .claudeModelsList(models: models)

      case "context_compacted":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        self = .contextCompacted(sessionId: sessionId)

      case "undo_started":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        self = .undoStarted(sessionId: sessionId, message: message)

      case "undo_completed":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let success = try container.decode(Bool.self, forKey: .success)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        self = .undoCompleted(sessionId: sessionId, success: success, message: message)

      case "thread_rolled_back":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let numTurns = try container.decode(UInt32.self, forKey: .numTurns)
        self = .threadRolledBack(sessionId: sessionId, numTurns: numTurns)

      case "session_forked":
        let sourceSessionId = try container.decode(String.self, forKey: .sourceSessionId)
        let newSessionId = try container.decode(String.self, forKey: .newSessionId)
        let forkedFromThreadId = try container.decodeIfPresent(String.self, forKey: .forkedFromThreadId)
        self = .sessionForked(
          sourceSessionId: sourceSessionId,
          newSessionId: newSessionId,
          forkedFromThreadId: forkedFromThreadId
        )

      case "turn_diff_snapshot":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let turnId = try container.decode(String.self, forKey: .turnId)
        let diff = try container.decode(String.self, forKey: .diff)
        let inputTokens = try container.decodeIfPresent(UInt64.self, forKey: .inputTokens)
        let outputTokens = try container.decodeIfPresent(UInt64.self, forKey: .outputTokens)
        let cachedTokens = try container.decodeIfPresent(UInt64.self, forKey: .cachedTokens)
        let contextWindow = try container.decodeIfPresent(UInt64.self, forKey: .contextWindow)
        let snapshotKind =
          try container.decodeIfPresent(ServerTokenUsageSnapshotKind.self, forKey: .snapshotKind) ?? .unknown
        self = .turnDiffSnapshot(
          sessionId: sessionId,
          turnId: turnId,
          diff: diff,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cachedTokens: cachedTokens,
          contextWindow: contextWindow,
          snapshotKind: snapshotKind
        )

      case "review_comment_created":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let reviewRevision = try container.decode(UInt64.self, forKey: .reviewRevision)
        let comment = try container.decode(ServerReviewComment.self, forKey: .comment)
        self = .reviewCommentCreated(sessionId: sessionId, reviewRevision: reviewRevision, comment: comment)

      case "review_comment_updated":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let reviewRevision = try container.decode(UInt64.self, forKey: .reviewRevision)
        let comment = try container.decode(ServerReviewComment.self, forKey: .comment)
        self = .reviewCommentUpdated(sessionId: sessionId, reviewRevision: reviewRevision, comment: comment)

      case "review_comment_deleted":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let reviewRevision = try container.decode(UInt64.self, forKey: .reviewRevision)
        let commentId = try container.decode(String.self, forKey: .commentId)
        self = .reviewCommentDeleted(sessionId: sessionId, reviewRevision: reviewRevision, commentId: commentId)

      case "review_comments_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let reviewRevision = try container.decode(UInt64.self, forKey: .reviewRevision)
        let comments = try container.decode([ServerReviewComment].self, forKey: .comments)
        self = .reviewCommentsList(sessionId: sessionId, reviewRevision: reviewRevision, comments: comments)

      case "subagent_tools_list":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let subagentId = try container.decode(String.self, forKey: .subagentId)
        let tools = try container.decode([ServerSubagentTool].self, forKey: .tools)
        self = .subagentToolsList(sessionId: sessionId, subagentId: subagentId, tools: tools)

      case "shell_started":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let requestId = try container.decode(String.self, forKey: .requestId)
        let command = try container.decode(String.self, forKey: .command)
        self = .shellStarted(sessionId: sessionId, requestId: requestId, command: command)

      case "shell_output":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let requestId = try container.decode(String.self, forKey: .requestId)
        let stdout = try container.decode(String.self, forKey: .stdout)
        let stderr = try container.decode(String.self, forKey: .stderr)
        let exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        let durationMs = try container.decode(UInt64.self, forKey: .durationMs)
        let outcome = try container.decodeIfPresent(ServerShellExecutionOutcome.self, forKey: .outcome)
          ?? ((exitCode == 0) ? .completed : .failed)
        self = .shellOutput(
          sessionId: sessionId, requestId: requestId,
          stdout: stdout, stderr: stderr, exitCode: exitCode, durationMs: durationMs, outcome: outcome
        )

      case "directory_listing":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let path = try container.decode(String.self, forKey: .path)
        let entries = try container.decode([ServerDirectoryEntry].self, forKey: .entries)
        self = .directoryListing(requestId: requestId, path: path, entries: entries)

      case "recent_projects_list":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let projects = try container.decode([ServerRecentProject].self, forKey: .projects)
        self = .recentProjectsList(requestId: requestId, projects: projects)

      case "codex_usage_result":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let usage = try container.decodeIfPresent(ServerCodexUsageSnapshot.self, forKey: .usage)
        let errorInfo = try container.decodeIfPresent(ServerUsageErrorInfo.self, forKey: .errorInfo)
        self = .codexUsageResult(requestId: requestId, usage: usage, errorInfo: errorInfo)

      case "claude_usage_result":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let usage = try container.decodeIfPresent(ServerClaudeUsageSnapshot.self, forKey: .usage)
        let errorInfo = try container.decodeIfPresent(ServerUsageErrorInfo.self, forKey: .errorInfo)
        self = .claudeUsageResult(requestId: requestId, usage: usage, errorInfo: errorInfo)

      case "open_ai_key_status":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let configured = try container.decode(Bool.self, forKey: .configured)
        self = .openAiKeyStatus(requestId: requestId, configured: configured)

      case "server_info":
        let isPrimary = try container.decode(Bool.self, forKey: .isPrimary)
        let clientPrimaryClaims =
          try container.decodeIfPresent([ServerClientPrimaryClaim].self, forKey: .clientPrimaryClaims) ?? []
        self = .serverInfo(isPrimary: isPrimary, clientPrimaryClaims: clientPrimaryClaims)

      case "approval_decision_result":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let requestId = try container.decode(String.self, forKey: .requestId)
        let outcome = try container.decode(String.self, forKey: .outcome)
        let activeRequestId = try container.decodeIfPresent(String.self, forKey: .activeRequestId)
        let approvalVersion = try container.decode(UInt64.self, forKey: .approvalVersion)
        self = .approvalDecisionResult(
          sessionId: sessionId,
          requestId: requestId,
          outcome: outcome,
          activeRequestId: activeRequestId,
          approvalVersion: approvalVersion
        )

      case "worktrees_list":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let repoRoot = try container.decodeIfPresent(String.self, forKey: .repoRoot)
        let worktreeRevision = try container.decode(UInt64.self, forKey: .worktreeRevision)
        let worktrees = try container.decode([ServerWorktreeSummary].self, forKey: .worktrees)
        self = .worktreesList(
          requestId: requestId, repoRoot: repoRoot, worktreeRevision: worktreeRevision, worktrees: worktrees)

      case "worktree_created":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let repoRoot = try container.decode(String.self, forKey: .repoRoot)
        let worktreeRevision = try container.decode(UInt64.self, forKey: .worktreeRevision)
        let worktree = try container.decode(ServerWorktreeSummary.self, forKey: .worktree)
        self = .worktreeCreated(
          requestId: requestId, repoRoot: repoRoot, worktreeRevision: worktreeRevision, worktree: worktree)

      case "worktree_removed":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let repoRoot = try container.decode(String.self, forKey: .repoRoot)
        let worktreeRevision = try container.decode(UInt64.self, forKey: .worktreeRevision)
        let worktreeId = try container.decode(String.self, forKey: .worktreeId)
        self = .worktreeRemoved(
          requestId: requestId, repoRoot: repoRoot, worktreeRevision: worktreeRevision, worktreeId: worktreeId)

      case "worktree_status_changed":
        let worktreeId = try container.decode(String.self, forKey: .worktreeId)
        let status = try container.decode(ServerWorktreeStatus.self, forKey: .status)
        let repoRoot = try container.decode(String.self, forKey: .repoRoot)
        self = .worktreeStatusChanged(worktreeId: worktreeId, status: status, repoRoot: repoRoot)

      case "worktree_error":
        let requestId = try container.decode(String.self, forKey: .requestId)
        let code = try container.decode(String.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        self = .worktreeError(requestId: requestId, code: code, message: message)

      case "rate_limit_event":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let info = try container.decode(ServerRateLimitInfo.self, forKey: .info)
        self = .rateLimitEvent(sessionId: sessionId, info: info)

      case "prompt_suggestion":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let suggestion = try container.decode(String.self, forKey: .suggestion)
        self = .promptSuggestion(sessionId: sessionId, suggestion: suggestion)

      case "files_persisted":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
        self = .filesPersisted(sessionId: sessionId, files: files)

      case "permission_rules":
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let rules = try container.decode(ServerSessionPermissionRules.self, forKey: .rules)
        self = .permissionRules(sessionId: sessionId, rules: rules)

      case "error":
        let code = try container.decode(String.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self = .error(code: code, message: message, sessionId: sessionId)

      default:
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Unknown message type: \(type)"
          )
        )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case let .sessionsList(sessions):
        try container.encode("sessions_list", forKey: .type)
        try container.encode(sessions, forKey: .sessions)

      case let .sessionSnapshot(session):
        try container.encode("session_snapshot", forKey: .type)
        try container.encode(session, forKey: .session)

      case let .sessionDelta(sessionId, changes):
        try container.encode("session_delta", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(changes, forKey: .changes)

      case let .messageAppended(sessionId, message):
        try container.encode("message_appended", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(message, forKey: .message)

      case let .messageUpdated(sessionId, messageId, changes):
        try container.encode("message_updated", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(changes, forKey: .changes)

      case let .approvalRequested(sessionId, request, approvalVersion):
        try container.encode("approval_requested", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(approvalVersion, forKey: .approvalVersion)

      case let .tokensUpdated(sessionId, usage, snapshotKind):
        try container.encode("tokens_updated", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(usage, forKey: .usage)
        try container.encode(snapshotKind, forKey: .snapshotKind)

      case let .sessionCreated(session):
        try container.encode("session_created", forKey: .type)
        try container.encode(session, forKey: .session)

      case let .sessionEnded(sessionId, reason):
        try container.encode("session_ended", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(reason, forKey: .reason)

      case let .approvalsList(sessionId, approvals):
        try container.encode("approvals_list", forKey: .type)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(approvals, forKey: .approvals)

      case let .approvalDeleted(approvalId):
        try container.encode("approval_deleted", forKey: .type)
        try container.encode(approvalId, forKey: .approvalId)

      case let .modelsList(models):
        try container.encode("models_list", forKey: .type)
        try container.encode(models, forKey: .models)

      case let .codexAccountStatus(status):
        try container.encode("codex_account_status", forKey: .type)
        try container.encode(status, forKey: .status)

      case let .codexLoginChatgptStarted(loginId, authUrl):
        try container.encode("codex_login_chatgpt_started", forKey: .type)
        try container.encode(loginId, forKey: .loginId)
        try container.encode(authUrl, forKey: .authUrl)

      case let .codexLoginChatgptCompleted(loginId, success, error):
        try container.encode("codex_login_chatgpt_completed", forKey: .type)
        try container.encode(loginId, forKey: .loginId)
        try container.encode(success, forKey: .success)
        try container.encodeIfPresent(error, forKey: .error)

      case let .codexLoginChatgptCanceled(loginId, status):
        try container.encode("codex_login_chatgpt_canceled", forKey: .type)
        try container.encode(loginId, forKey: .loginId)
        try container.encode(status, forKey: .status)

      case let .codexAccountUpdated(status):
        try container.encode("codex_account_updated", forKey: .type)
        try container.encode(status, forKey: .status)

      case let .skillsList(sessionId, skills, errors):
        try container.encode("skills_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(skills, forKey: .skills)
        try container.encode(errors, forKey: .errors)

      case let .remoteSkillsList(sessionId, skills):
        try container.encode("remote_skills_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(skills, forKey: .skills)

      case let .remoteSkillDownloaded(sessionId, skillId, name, path):
        try container.encode("remote_skill_downloaded", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(skillId, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)

      case let .skillsUpdateAvailable(sessionId):
        try container.encode("skills_update_available", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .mcpToolsList(sessionId, tools, resources, resourceTemplates, authStatuses):
        try container.encode("mcp_tools_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(tools, forKey: .tools)
        try container.encode(resources, forKey: .resources)
        try container.encode(resourceTemplates, forKey: .resourceTemplates)
        try container.encode(authStatuses, forKey: .authStatuses)

      case let .mcpStartupUpdate(sessionId, server, status):
        try container.encode("mcp_startup_update", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(server, forKey: .server)
        try container.encode(status, forKey: .status)

      case let .mcpStartupComplete(sessionId, ready, failed, cancelled):
        try container.encode("mcp_startup_complete", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(ready, forKey: .ready)
        try container.encode(failed, forKey: .failed)
        try container.encode(cancelled, forKey: .cancelled)

      case let .claudeCapabilities(sessionId, slashCommands, skills, tools, models):
        try container.encode("claude_capabilities", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(slashCommands, forKey: .slashCommands)
        try container.encode(skills, forKey: .skills)
        try container.encode(tools, forKey: .tools)
        try container.encode(models, forKey: .models)

      case let .claudeModelsList(models):
        try container.encode("claude_models_list", forKey: .type)
        try container.encode(models, forKey: .models)

      case let .contextCompacted(sessionId):
        try container.encode("context_compacted", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)

      case let .undoStarted(sessionId, message):
        try container.encode("undo_started", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(message, forKey: .message)

      case let .undoCompleted(sessionId, success, message):
        try container.encode("undo_completed", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(success, forKey: .success)
        try container.encodeIfPresent(message, forKey: .message)

      case let .threadRolledBack(sessionId, numTurns):
        try container.encode("thread_rolled_back", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(numTurns, forKey: .numTurns)

      case let .sessionForked(sourceSessionId, newSessionId, forkedFromThreadId):
        try container.encode("session_forked", forKey: .type)
        try container.encode(sourceSessionId, forKey: .sourceSessionId)
        try container.encode(newSessionId, forKey: .newSessionId)
        try container.encodeIfPresent(forkedFromThreadId, forKey: .forkedFromThreadId)

      case let .turnDiffSnapshot(
      sessionId,
      turnId,
      diff,
      inputTokens,
      outputTokens,
      cachedTokens,
      contextWindow,
      snapshotKind
    ):
        try container.encode("turn_diff_snapshot", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(turnId, forKey: .turnId)
        try container.encode(diff, forKey: .diff)
        try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try container.encodeIfPresent(outputTokens, forKey: .outputTokens)
        try container.encodeIfPresent(cachedTokens, forKey: .cachedTokens)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try container.encode(snapshotKind, forKey: .snapshotKind)

      case let .reviewCommentCreated(sessionId, reviewRevision, comment):
        try container.encode("review_comment_created", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(reviewRevision, forKey: .reviewRevision)
        try container.encode(comment, forKey: .comment)

      case let .reviewCommentUpdated(sessionId, reviewRevision, comment):
        try container.encode("review_comment_updated", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(reviewRevision, forKey: .reviewRevision)
        try container.encode(comment, forKey: .comment)

      case let .reviewCommentDeleted(sessionId, reviewRevision, commentId):
        try container.encode("review_comment_deleted", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(reviewRevision, forKey: .reviewRevision)
        try container.encode(commentId, forKey: .commentId)

      case let .reviewCommentsList(sessionId, reviewRevision, comments):
        try container.encode("review_comments_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(reviewRevision, forKey: .reviewRevision)
        try container.encode(comments, forKey: .comments)

      case let .subagentToolsList(sessionId, subagentId, tools):
        try container.encode("subagent_tools_list", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(subagentId, forKey: .subagentId)
        try container.encode(tools, forKey: .tools)

      case let .shellStarted(sessionId, requestId, command):
        try container.encode("shell_started", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(command, forKey: .command)

      case let .shellOutput(sessionId, requestId, stdout, stderr, exitCode, durationMs, outcome):
        try container.encode("shell_output", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(stderr, forKey: .stderr)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(outcome, forKey: .outcome)

      case let .directoryListing(requestId, path, entries):
        try container.encode("directory_listing", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(path, forKey: .path)
        try container.encode(entries, forKey: .entries)

      case let .recentProjectsList(requestId, projects):
        try container.encode("recent_projects_list", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(projects, forKey: .projects)

      case let .codexUsageResult(requestId, usage, errorInfo):
        try container.encode("codex_usage_result", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(errorInfo, forKey: .errorInfo)

      case let .claudeUsageResult(requestId, usage, errorInfo):
        try container.encode("claude_usage_result", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(errorInfo, forKey: .errorInfo)

      case let .openAiKeyStatus(requestId, configured):
        try container.encode("open_ai_key_status", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(configured, forKey: .configured)

      case let .serverInfo(isPrimary, clientPrimaryClaims):
        try container.encode("server_info", forKey: .type)
        try container.encode(isPrimary, forKey: .isPrimary)
        if !clientPrimaryClaims.isEmpty {
          try container.encode(clientPrimaryClaims, forKey: .clientPrimaryClaims)
        }

      case let .approvalDecisionResult(sessionId, requestId, outcome, activeRequestId, approvalVersion):
        try container.encode("approval_decision_result", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(activeRequestId, forKey: .activeRequestId)
        try container.encode(approvalVersion, forKey: .approvalVersion)

      case let .worktreesList(requestId, repoRoot, worktreeRevision, worktrees):
        try container.encode("worktrees_list", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(repoRoot, forKey: .repoRoot)
        try container.encode(worktreeRevision, forKey: .worktreeRevision)
        try container.encode(worktrees, forKey: .worktrees)

      case let .worktreeCreated(requestId, repoRoot, worktreeRevision, worktree):
        try container.encode("worktree_created", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(repoRoot, forKey: .repoRoot)
        try container.encode(worktreeRevision, forKey: .worktreeRevision)
        try container.encode(worktree, forKey: .worktree)

      case let .worktreeRemoved(requestId, repoRoot, worktreeRevision, worktreeId):
        try container.encode("worktree_removed", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(repoRoot, forKey: .repoRoot)
        try container.encode(worktreeRevision, forKey: .worktreeRevision)
        try container.encode(worktreeId, forKey: .worktreeId)

      case let .worktreeStatusChanged(worktreeId, status, repoRoot):
        try container.encode("worktree_status_changed", forKey: .type)
        try container.encode(worktreeId, forKey: .worktreeId)
        try container.encode(status, forKey: .status)
        try container.encode(repoRoot, forKey: .repoRoot)

      case let .worktreeError(requestId, code, message):
        try container.encode("worktree_error", forKey: .type)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)

      case let .rateLimitEvent(sessionId, info):
        try container.encode("rate_limit_event", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(info, forKey: .info)

      case let .promptSuggestion(sessionId, suggestion):
        try container.encode("prompt_suggestion", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(suggestion, forKey: .suggestion)

      case let .filesPersisted(sessionId, files):
        try container.encode("files_persisted", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(files, forKey: .files)

      case let .permissionRules(sessionId, rules):
        try container.encode("permission_rules", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(rules, forKey: .rules)

      case let .error(code, message, sessionId):
        try container.encode("error", forKey: .type)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
    }
  }
}
