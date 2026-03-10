import Foundation

extension ServerToClientMessage {
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
}
