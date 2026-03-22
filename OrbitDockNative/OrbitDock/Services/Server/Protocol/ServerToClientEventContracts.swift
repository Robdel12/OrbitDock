//
//  ServerToClientEventContracts.swift
//  OrbitDock
//
//  Server-to-client WebSocket event contracts grouped by event surface.
//

import Foundation

enum ServerToClientMessage: Codable {
  // MARK: Session lifecycle and conversation

  case sessionsList(sessions: [ServerSessionListItem])
  case dashboardConversationsUpdated(conversations: [ServerDashboardConversationItem])
  case conversationBootstrap(session: ServerSessionState, conversation: ServerConversationHistoryPage)
  case sessionSnapshot(session: ServerSessionState)
  case sessionDelta(sessionId: String, changes: ServerStateChanges)
  case conversationRowsChanged(
    sessionId: String,
    upserted: [ServerConversationRowEntry],
    removedRowIds: [String],
    totalRowCount: UInt64?
  )
  case tokensUpdated(sessionId: String, usage: ServerTokenUsage, snapshotKind: ServerTokenUsageSnapshotKind)
  case sessionCreated(session: ServerSessionListItem)
  case sessionListItemUpdated(session: ServerSessionListItem)
  case sessionListItemRemoved(sessionId: String)
  case sessionEnded(sessionId: String, reason: String)
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
  case promptSuggestion(sessionId: String, suggestion: String)
  case filesPersisted(sessionId: String, files: [String])
  case permissionRules(sessionId: String, rules: ServerSessionPermissionRules)
  case rateLimitEvent(sessionId: String, info: ServerRateLimitInfo)

  // MARK: Approvals and review

  case approvalRequested(sessionId: String, request: ServerApprovalRequest, approvalVersion: UInt64?)
  case approvalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem])
  case approvalDeleted(approvalId: Int64)
  case approvalDecisionResult(
    sessionId: String,
    requestId: String,
    outcome: String,
    activeRequestId: String?,
    approvalVersion: UInt64
  )
  case reviewCommentCreated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentUpdated(sessionId: String, reviewRevision: UInt64, comment: ServerReviewComment)
  case reviewCommentDeleted(sessionId: String, reviewRevision: UInt64, commentId: String)
  case reviewCommentsList(sessionId: String, reviewRevision: UInt64, comments: [ServerReviewComment])

  // MARK: Provider capabilities and auth

  case modelsList(models: [ServerCodexModelOption])
  case codexAccountStatus(status: ServerCodexAccountStatus)
  case codexLoginChatgptStarted(loginId: String, authUrl: String)
  case codexLoginChatgptCompleted(loginId: String, success: Bool, error: String?)
  case codexLoginChatgptCanceled(loginId: String, status: ServerCodexLoginCancelStatus)
  case codexAccountUpdated(status: ServerCodexAccountStatus)
  case claudeCapabilities(
    sessionId: String,
    slashCommands: [String],
    skills: [String],
    tools: [String],
    models: [ServerClaudeModelOption]
  )
  case claudeModelsList(models: [ServerClaudeModelOption])
  case skillsList(sessionId: String, skills: [ServerSkillsListEntry], errors: [ServerSkillErrorInfo])
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
  case subagentToolsList(sessionId: String, subagentId: String, tools: [ServerSubagentTool])

  // MARK: Shell, files, and usage

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

  // MARK: Server and worktrees

  case serverInfo(isPrimary: Bool, clientPrimaryClaims: [ServerClientPrimaryClaim])
  case worktreesList(requestId: String, repoRoot: String?, worktreeRevision: UInt64, worktrees: [ServerWorktreeSummary])
  case worktreeCreated(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktree: ServerWorktreeSummary)
  case worktreeRemoved(requestId: String, repoRoot: String, worktreeRevision: UInt64, worktreeId: String)
  case worktreeStatusChanged(worktreeId: String, status: ServerWorktreeStatus, repoRoot: String)
  case worktreeError(requestId: String, code: String, message: String)

  // MARK: Errors

  case error(code: String, message: String, sessionId: String?)

  // MARK: Mission Control

  case missionsList(missions: [MissionSummary])
  case missionDelta(missionId: String, issues: [MissionIssueItem], summary: MissionSummary)
  case missionHeartbeat(missionId: String, tickStartedAt: String, nextTickAt: String)

  // MARK: Unknown (resilience)

  /// Server sent a message type the client doesn't recognize.
  /// Logged at decode time; the event router ignores this case.
  case unknown(type: String)
}
