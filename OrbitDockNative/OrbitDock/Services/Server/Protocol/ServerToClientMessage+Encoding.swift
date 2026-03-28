import Foundation

extension ServerToClientMessage {
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case let .hello(hello):
        try container.encode("hello", forKey: .type)
        try container.encode(hello, forKey: .hello)

      case let .dashboardInvalidated(revision):
        try container.encode("dashboard_invalidated", forKey: .type)
        try container.encode(revision, forKey: .revision)

      case let .missionsInvalidated(revision):
        try container.encode("missions_invalidated", forKey: .type)
        try container.encode(revision, forKey: .revision)

      case let .sessionDelta(sessionId, changes):
        try container.encode("session_delta", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(changes, forKey: .changes)

      case let .conversationRowsChanged(sessionId, upserted, removedRowIds, totalRowCount):
        try container.encode("conversation_rows_changed", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(upserted, forKey: .upserted)
        try container.encode(removedRowIds, forKey: .removedRowIds)
        try container.encodeIfPresent(totalRowCount, forKey: .totalRowCount)

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

      case let .missionsList(missions):
        try container.encode("missions_list", forKey: .type)
        try container.encode(missions, forKey: .missions)

      case let .missionDelta(missionId, issues, summary):
        try container.encode("mission_delta", forKey: .type)
        try container.encode(missionId, forKey: .missionId)
        try container.encode(issues, forKey: .issues)
        try container.encode(summary, forKey: .summary)

      case let .missionHeartbeat(missionId, tickStartedAt, nextTickAt):
        try container.encode("mission_heartbeat", forKey: .type)
        try container.encode(missionId, forKey: .missionId)
        try container.encode(tickStartedAt, forKey: .tickStartedAt)
        try container.encode(nextTickAt, forKey: .nextTickAt)

      case let .steerOutcome(sessionId, messageId, outcome):
        try container.encode("steer_outcome", forKey: .type)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(outcome, forKey: .outcome)

      case let .terminalCreated(terminalId, sessionId):
        try container.encode("terminal_created", forKey: .type)
        try container.encode(terminalId, forKey: .terminalId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)

      case let .terminalExited(terminalId, exitCode):
        try container.encode("terminal_exited", forKey: .type)
        try container.encode(terminalId, forKey: .terminalId)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)

      case let .error(code, message, sessionId):
        try container.encode("error", forKey: .type)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)

      case let .unknown(type):
        try container.encode(type, forKey: .type)
    }
  }
}
