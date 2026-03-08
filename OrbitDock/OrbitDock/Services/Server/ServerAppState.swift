//
//  ServerAppState.swift
//  OrbitDock
//
//  WebSocket-backed state store for server-managed sessions.
//  Listens to ServerConnection callbacks and maintains Session/TranscriptMessage
//  state that views can observe. Per-session state lives in SessionObservable;
//  this class is a registry + global state holder.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "server-app-state")

@Observable
@MainActor
final class ServerAppState {
  nonisolated static func codexModelsCacheKey(endpointId: UUID) -> String {
    "orbitdock.server.codex_models_cache.v2.\(endpointId.uuidString)"
  }

  nonisolated static func sessionsCacheKey(endpointId: UUID) -> String {
    "orbitdock.server.sessions_cache.v2.\(endpointId.uuidString)"
  }

  @ObservationIgnored
  let connection: ServerConnection

  /// Shared project file index used by composer mention/file-pick flows.
  /// Long-lived ownership in app state avoids view lifecycle races.
  @ObservationIgnored
  private let sharedProjectFileIndex = ProjectFileIndex()

  @ObservationIgnored
  private let conversationReadModel = ConversationReadModelStore()
  private let conversationPageSize = 50

  let endpointId: UUID

  private var codexModelsCacheKey: String {
    Self.codexModelsCacheKey(endpointId: endpointId)
  }

  private var sessionsCacheKey: String {
    Self.sessionsCacheKey(endpointId: endpointId)
  }

  // MARK: - Observable State (global, not per-session)

  /// Sessions managed by the server (converted to Session model for view compatibility)
  private(set) var sessions: [Session] = [] {
    didSet {
      guard oldValue != sessions else { return }
      NotificationCenter.default.post(
        name: .serverSessionsDidChange,
        object: nil,
        userInfo: ["endpointId": endpointId]
      )
    }
  }

  private(set) var hasReceivedInitialSessionsList = false

  /// Cross-session approval history (global view)
  private(set) var globalApprovalHistory: [ServerApprovalHistoryItem] = []

  /// Codex models discovered by the server for the current account
  private(set) var codexModels: [ServerCodexModelOption] = []

  /// Claude models discovered from Claude CLI initialize response
  private(set) var claudeModels: [ServerClaudeModelOption] = []

  /// Current Codex account/auth status (global account state, not per-session)
  private(set) var codexAccountStatus: ServerCodexAccountStatus?

  /// Most recent Codex auth/login error suitable for UI display
  private(set) var codexAuthError: String?

  /// Most recent unhandled server error — surfaced as a toast/alert so errors are never silent
  private(set) var lastServerError: (code: String, message: String)?

  /// Worktrees keyed by repo_root (or "all" for unscoped lists)
  private(set) var worktreesByRepo: [String: [ServerWorktreeSummary]] = [:]

  // MARK: - Per-Session Observable Registry

  @ObservationIgnored
  private var _sessionObservables: [String: SessionObservable] = [:]

  /// Get or create per-session observable. Does NOT trigger observation on ServerAppState.
  func session(_ id: String) -> SessionObservable {
    if let existing = _sessionObservables[id] { return existing }
    let obs = SessionObservable(id: id)
    _sessionObservables[id] = obs
    return obs
  }

  /// Copy all Session struct fields to the per-session observable so detail views
  /// can read from the observable instead of the struct.
  func hydrateObservable(_ obs: SessionObservable, from sess: Session) {
    obs.endpointId = sess.endpointId
    obs.endpointName = sess.endpointName
    obs.projectPath = sess.projectPath
    obs.projectName = sess.projectName
    obs.branch = sess.branch
    obs.model = sess.model
    obs.effort = sess.effort
    obs.summary = sess.summary
    obs.customName = sess.customName
    obs.firstPrompt = sess.firstPrompt
    obs.lastMessage = sess.lastMessage
    obs.transcriptPath = sess.transcriptPath
    obs.status = sess.status
    obs.workStatus = sess.workStatus
    obs.attentionReason = sess.attentionReason
    obs.lastActivityAt = sess.lastActivityAt
    obs.lastTool = sess.lastTool
    obs.lastToolAt = sess.lastToolAt
    obs.inputTokens = sess.inputTokens
    obs.outputTokens = sess.outputTokens
    obs.cachedTokens = sess.cachedTokens
    obs.contextWindow = sess.contextWindow
    obs.totalTokens = sess.totalTokens
    obs.totalCostUSD = sess.totalCostUSD
    obs.provider = sess.provider
    obs.codexIntegrationMode = sess.codexIntegrationMode
    obs.claudeIntegrationMode = sess.claudeIntegrationMode
    obs.codexThreadId = sess.codexThreadId
    obs.pendingApprovalId = sess.pendingApprovalId
    obs.pendingToolName = sess.pendingToolName
    obs.pendingToolInput = sess.pendingToolInput
    obs.pendingPermissionDetail = sess.pendingPermissionDetail
    obs.pendingQuestion = sess.pendingQuestion
    obs.promptCount = sess.promptCount
    obs.toolCount = sess.toolCount
    obs.startedAt = sess.startedAt
    obs.endedAt = sess.endedAt
    obs.endReason = sess.endReason
    obs.tokenUsageSnapshotKind = sess.tokenUsageSnapshotKind
    obs.gitSha = sess.gitSha
    obs.currentCwd = sess.currentCwd
    obs.repositoryRoot = sess.repositoryRoot
    obs.isWorktree = sess.isWorktree
    obs.worktreeId = sess.worktreeId
    obs.unreadCount = sess.unreadCount
  }

  /// Worktrees for a given repo root
  func worktrees(for repoRoot: String) -> [ServerWorktreeSummary] {
    worktreesByRepo[repoRoot] ?? []
  }

  /// Shared project file index for mention completion and file picker flows.
  var projectFileIndex: ProjectFileIndex {
    sharedProjectFileIndex
  }

  /// Fetch worktree data for all unique project paths from active sessions.
  /// Called after sessions list loads and on reconnect — views just read.
  func refreshWorktreesForActiveSessions() {
    let roots = Set(
      sessions
        .filter(\.isActive)
        .map(\.groupingPath)
    )
    for root in roots {
      connection.listWorktrees(repoRoot: root)
    }
  }

  // MARK: - Private Internal State

  /// Last known server revision per session (for incremental reconnection)
  private var lastRevision: [String: UInt64] = [:]

  /// Raw config values used to derive autonomy accurately across partial deltas
  private var approvalPolicies: [String: String] = [:]
  private var sandboxModes: [String: String] = [:]
  private var permissionModes: [String: String] = [:]

  /// Track which sessions we're subscribed to
  private var subscribedSessions: Set<String> = []

  /// Sessions that are genuinely being read right now: visible and following the bottom.
  private var autoMarkReadSessions: Set<String> = []

  /// Temporary: autonomy level from the most recent createSession call
  private var pendingCreationAutonomy: AutonomyLevel?

  /// Debounced disk writes for per-session conversation snapshots.
  @ObservationIgnored
  private var pendingConversationCacheWrites: [String: Task<Void, Never>] = [:]
  @ObservationIgnored
  private var pendingConversationCacheWriteModes: [String: ConversationCacheWriteMode] = [:]

  /// When true, navigate to the next session that gets created
  private var pendingNavigationOnCreate = false

  /// Optional bootstrap prompt to send once the locally-created session is ready.
  private var pendingCreateInitialPrompt: String?

  /// Session ID learned from the creator-only snapshot so follow-up automation only
  /// targets the session that this client actually created.
  private var pendingCreatePromptTargetSessionId: String?

  private struct ApprovalDispatchKey: Hashable {
    let sessionId: String
    let requestId: String
  }

  private enum ConversationCacheWriteMode {
    case metadataOnly
    case upsertMessages([TranscriptMessage])
    case replaceLoadedWindow

    var debugName: String {
      switch self {
        case .metadataOnly: return "metadata-only"
        case .upsertMessages: return "upsert-messages"
        case .replaceLoadedWindow: return "replace-loaded-window"
      }
    }

    mutating func merge(with other: ConversationCacheWriteMode) {
      switch (self, other) {
        case (.replaceLoadedWindow, _), (_, .replaceLoadedWindow):
          self = .replaceLoadedWindow
        case (.metadataOnly, .metadataOnly), (.upsertMessages, .metadataOnly):
          break
        case (.metadataOnly, .upsertMessages(let messages)):
          self = .upsertMessages(messages)
        case (.upsertMessages(let existing), .upsertMessages(let incoming)):
          self = .upsertMessages(Self.mergeUpserts(existing: existing, incoming: incoming))
      }
    }

    private static func mergeUpserts(
      existing: [TranscriptMessage],
      incoming: [TranscriptMessage]
    ) -> [TranscriptMessage] {
      var mergedByID: [String: TranscriptMessage] = [:]
      for message in existing {
        mergedByID[message.id] = message
      }
      for message in incoming {
        mergedByID[message.id] = message
      }
      return mergedByID.values.sorted { lhs, rhs in
        let lhsSequence = lhs.sequence ?? UInt64.max
        let rhsSequence = rhs.sequence ?? UInt64.max
        if lhsSequence != rhsSequence {
          return lhsSequence < rhsSequence
        }
        if lhs.timestamp != rhs.timestamp {
          return lhs.timestamp < rhs.timestamp
        }
        return lhs.id < rhs.id
      }
    }
  }

  /// Client-side idempotency for approval/question decisions.
  private var inFlightApprovalDispatches: Set<ApprovalDispatchKey> = []

  /// Request details received for queued approvals that are not yet the active queue head.
  /// Keyed by `sessionId` then normalized `requestId`.
  private var queuedApprovalRequests: [String: [String: ServerApprovalRequest]] = [:]

  private struct SessionsCachePayload: Codable {
    let cachedAt: Date
    let summaries: [ServerSessionSummary]
  }

  enum ApprovalDispatchResult: Equatable {
    case dispatched
    case stale(nextPendingRequestId: String?)
  }

  init(connection: ServerConnection, endpointId: UUID) {
    self.connection = connection
    self.endpointId = endpointId

    if AppRuntimeMode.current == .mock {
      sessions = Self.mockSessions().map { s in
        var stamped = s
        stamped.endpointId = endpointId
        stamped.endpointName = connection.endpointName
        return stamped
      }
      hasReceivedInitialSessionsList = true
      return
    }

    if let cached = loadSessionsCache() {
      sessions = cached.summaries.map { summary in
        var s = summary.toSession()
        s.endpointId = endpointId
        s.endpointName = connection.endpointName
        return s
      }
      logger.info("Loaded cached sessions list: \(cached.summaries.count) sessions")
    }

    if let data = UserDefaults.standard.data(forKey: codexModelsCacheKey),
       let models = try? JSONDecoder().decode([ServerCodexModelOption].self, from: data)
    {
      codexModels = models
    }
  }

  convenience init() {
    let endpoint = ServerEndpointSettings.defaultEndpoint
    let connection = ServerConnection(endpoint: endpoint)
    self.init(connection: connection, endpointId: endpoint.id)
  }

  var codexAccount: ServerCodexAccount? {
    codexAccountStatus?.account
  }

  var codexAuthMode: ServerCodexAuthMode? {
    codexAccountStatus?.authMode
  }

  var codexRequiresOpenAIAuth: Bool {
    codexAccountStatus?.requiresOpenaiAuth ?? true
  }

  var codexLoginInProgress: Bool {
    codexAccountStatus?.loginInProgress ?? false
  }

  var codexActiveLoginId: String? {
    codexAccountStatus?.activeLoginId
  }

  var isLoadingInitialSessions: Bool {
    !hasReceivedInitialSessionsList && sessions.isEmpty
  }

  var isRefreshingCachedSessions: Bool {
    !hasReceivedInitialSessionsList && !sessions.isEmpty
  }

  // MARK: - Setup

  /// Wire up ServerConnection callbacks. Call after connection is established.
  func setup() {
    let conn = connection

    conn.onSessionsList = { [weak self] summaries in
      Task { @MainActor in
        self?.handleSessionsList(summaries)
      }
    }

    conn.onSessionSnapshot = { [weak self] state in
      Task { @MainActor in
        self?.handleSessionSnapshot(state)
      }
    }

    conn.onSessionDelta = { [weak self] sessionId, changes in
      Task { @MainActor in
        self?.handleSessionDelta(sessionId, changes)
      }
    }

    conn.onMessageAppended = { [weak self] sessionId, message in
      Task { @MainActor in
        self?.handleMessageAppended(sessionId, message)
      }
    }

    conn.onMessageUpdated = { [weak self] sessionId, messageId, changes in
      Task { @MainActor in
        self?.handleMessageUpdated(sessionId, messageId, changes)
      }
    }

    conn.onApprovalRequested = { [weak self] sessionId, request, approvalVersion in
      Task { @MainActor in
        self?.handleApprovalRequested(sessionId, request, approvalVersion: approvalVersion)
      }
    }

    conn.onApprovalDecisionResult = { [weak self] sessionId, requestId, outcome, activeRequestId, approvalVersion in
      Task { @MainActor in
        self?.handleApprovalDecisionResult(
          sessionId: sessionId,
          requestId: requestId,
          outcome: outcome,
          activeRequestId: activeRequestId,
          approvalVersion: approvalVersion
        )
      }
    }

    conn.onTokensUpdated = { [weak self] sessionId, usage, snapshotKind in
      Task { @MainActor in
        self?.handleTokensUpdated(sessionId, usage, snapshotKind: snapshotKind)
      }
    }

    conn.onSessionCreated = { [weak self] summary in
      Task { @MainActor in
        self?.handleSessionCreated(summary)
      }
    }

    conn.onSessionEnded = { [weak self] sessionId, reason in
      Task { @MainActor in
        self?.handleSessionEnded(sessionId, reason)
      }
    }

    conn.onApprovalsList = { [weak self] sessionId, approvals in
      Task { @MainActor in
        self?.handleApprovalsList(sessionId: sessionId, approvals: approvals)
      }
    }

    conn.onApprovalDeleted = { [weak self] approvalId in
      Task { @MainActor in
        self?.handleApprovalDeleted(approvalId: approvalId)
      }
    }

    conn.onModelsList = { [weak self] models in
      Task { @MainActor in
        self?.codexModels = models
        self?.persistCodexModelsCache(models)
      }
    }

    conn.onCodexAccountStatus = { [weak self] status in
      Task { @MainActor in
        self?.applyCodexAccountStatus(status)
      }
    }

    conn.onCodexLoginChatgptStarted = { [weak self] loginId, authUrl in
      Task { @MainActor in
        guard let self else { return }
        self.codexAuthError = nil
        self.markLoginInProgress(loginId: loginId)
        self.openCodexAuthURL(authUrl)
      }
    }

    conn.onCodexLoginChatgptCompleted = { [weak self] loginId, success, error in
      Task { @MainActor in
        guard let self else { return }
        if let activeLoginId = self.codexActiveLoginId, activeLoginId != loginId {
          logger.debug("Ignoring stale login completion for \(loginId)")
          return
        }
        self.markLoginInProgress(loginId: nil)
        if success {
          self.codexAuthError = nil
        } else {
          self.codexAuthError = error ?? "ChatGPT sign-in failed"
        }
        self.refreshCodexAccount()
      }
    }

    conn.onCodexLoginChatgptCanceled = { [weak self] loginId, status in
      Task { @MainActor in
        guard let self else { return }
        if let activeLoginId = self.codexActiveLoginId, activeLoginId != loginId {
          logger.debug("Ignoring stale login cancel for \(loginId)")
          return
        }
        self.markLoginInProgress(loginId: nil)
        switch status {
          case .canceled:
            self.codexAuthError = nil
          case .notFound:
            self.codexAuthError = "No active ChatGPT login was found to cancel."
          case .invalidId:
            self.codexAuthError = "Invalid login session. Please try signing in again."
        }
        self.refreshCodexAccount()
      }
    }

    conn.onCodexAccountUpdated = { [weak self] status in
      Task { @MainActor in
        self?.applyCodexAccountStatus(status)
      }
    }

    conn.onClaudeCapabilities = { [weak self] sessionId, slashCommands, skills, tools, models in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        if !slashCommands.isEmpty {
          obs.slashCommands = Set(slashCommands)
        }
        if !skills.isEmpty {
          obs.claudeSkillNames = skills
        }
        if !tools.isEmpty {
          obs.claudeToolNames = tools
        }
        if !models.isEmpty {
          self.claudeModels = models
        }
      }
    }

    conn.onClaudeModelsList = { [weak self] models in
      Task { @MainActor in
        if !models.isEmpty {
          self?.claudeModels = models
        }
      }
    }

    conn.onSkillsList = { [weak self] sessionId, entries, _ in
      Task { @MainActor in
        let allSkills = entries.flatMap(\.skills)
        self?.session(sessionId).skills = allSkills
      }
    }

    conn.onSkillsUpdateAvailable = { [weak self] sessionId in
      Task { @MainActor in
        self?.connection.listSkills(sessionId: sessionId)
      }
    }

    conn.onMcpToolsList = { [weak self] sessionId, tools, resources, _, authStatuses in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        obs.mcpTools = tools
        obs.mcpResources = resources
        obs.mcpAuthStatuses = authStatuses
        logger.info("MCP tools list received for \(sessionId): \(tools.count) tools")
      }
    }

    conn.onMcpStartupUpdate = { [weak self] sessionId, server, status in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        var state = obs.mcpStartupState ?? McpStartupState()
        state.serverStatuses[server] = status
        obs.mcpStartupState = state
        logger.info("MCP startup update for \(sessionId): \(server)")
      }
    }

    conn.onMcpStartupComplete = { [weak self] sessionId, ready, failed, cancelled in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        var state = obs.mcpStartupState ?? McpStartupState()
        state.readyServers = ready
        state.failedServers = failed
        state.cancelledServers = cancelled
        state.isComplete = true
        obs.mcpStartupState = state
        logger.info("MCP startup complete for \(sessionId): \(ready.count) ready, \(failed.count) failed")
        if self.shouldRequestCodexConnectorData(sessionId: sessionId) {
          self.connection.listMcpTools(sessionId: sessionId)
        }
      }
    }

    conn
      .onTurnDiffSnapshot =
      { [weak self] sessionId, turnId, diff, inputTokens, outputTokens, cachedTokens, contextWindow, snapshotKind in
        Task { @MainActor in
          self?.handleTurnDiffSnapshot(
            sessionId,
            turnId: turnId,
            diff: diff,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedTokens: cachedTokens,
            contextWindow: contextWindow,
            snapshotKind: snapshotKind
          )
        }
      }

    conn.onReviewCommentCreated = { [weak self] sessionId, comment in
      Task { @MainActor in
        self?.handleReviewCommentCreated(sessionId, comment: comment)
      }
    }

    conn.onReviewCommentUpdated = { [weak self] sessionId, comment in
      Task { @MainActor in
        self?.handleReviewCommentUpdated(sessionId, comment: comment)
      }
    }

    conn.onReviewCommentDeleted = { [weak self] sessionId, commentId in
      Task { @MainActor in
        self?.handleReviewCommentDeleted(sessionId, commentId: commentId)
      }
    }

    conn.onReviewCommentsList = { [weak self] sessionId, comments in
      Task { @MainActor in
        self?.session(sessionId).reviewComments = comments
      }
    }

    conn.onSubagentToolsList = { [weak self] sessionId, subagentId, tools in
      Task { @MainActor in
        self?.session(sessionId).subagentTools[subagentId] = tools
      }
    }

    conn.onShellOutput = { [weak self] sessionId, requestId, stdout, stderr, exitCode, durationMs, outcome in
      Task { @MainActor in
        guard let self else { return }
        let obs = self.session(sessionId)
        let output = stderr.isEmpty ? stdout : (stdout.isEmpty ? stderr : "\(stdout)\n\(stderr)")
        let isError = self.shellOutputIsError(outcome: outcome, exitCode: exitCode)
        // Find the shell message to get the command
        let command = obs.messages.first(where: { $0.id == requestId })?.content ?? ""
        obs.bufferShellContext(command: command, output: output, exitCode: exitCode)

        // Update the in-progress shell message with output
        if let idx = obs.messages.firstIndex(where: { $0.id == requestId }) {
          obs.messages[idx].toolOutput = output
          obs.messages[idx].toolDuration = Double(durationMs) / 1_000.0
          obs.messages[idx].isError = isError
          obs.messages[idx].isInProgress = false
          obs.bumpMessagesRevision(.upsert(obs.messages[idx]))
          self.queueConversationSnapshotWrite(
            sessionId: sessionId,
            reason: "shell-output",
            mode: .upsertMessages([obs.messages[idx]])
          )
        }
      }
    }

    conn.onContextCompacted = { [weak self] sessionId in
      Task { @MainActor in
        self?.handleContextCompacted(sessionId)
      }
    }

    conn.onUndoStarted = { [weak self] sessionId, _ in
      Task { @MainActor in
        self?.session(sessionId).undoInProgress = true
      }
    }

    conn.onUndoCompleted = { [weak self] sessionId, _, _ in
      Task { @MainActor in
        self?.session(sessionId).undoInProgress = false
      }
    }

    conn.onRateLimitEvent = { [weak self] sessionId, info in
      Task { @MainActor in
        self?.session(sessionId).rateLimitInfo = info
      }
    }

    conn.onPromptSuggestion = { [weak self] sessionId, suggestion in
      Task { @MainActor in
        let obs = self?.session(sessionId)
        if !(obs?.promptSuggestions.contains(suggestion) ?? true) {
          obs?.promptSuggestions.append(suggestion)
        }
      }
    }

    conn.onFilesPersisted = { [weak self] sessionId, _ in
      Task { @MainActor in
        self?.session(sessionId).lastFilesPersistedAt = Date()
      }
    }

    conn.onRevision = { [weak self] sessionId, revision in
      Task { @MainActor in
        self?.lastRevision[sessionId] = revision
      }
    }

    conn.onSessionForked = { [weak self] sourceSessionId, newSessionId, _ in
      Task { @MainActor in
        guard let self else { return }
        self.session(sourceSessionId).forkInProgress = false
        self.session(newSessionId).forkedFrom = sourceSessionId
        logger.info("Fork tracked: \(newSessionId) forked from \(sourceSessionId)")
        NotificationCenter.default.post(
          name: .selectSession,
          object: nil,
          userInfo: ["sessionId": SessionRef(endpointId: self.endpointId, sessionId: newSessionId).scopedID]
        )
      }
    }

    // Worktree management
    conn.onWorktreesList = { [weak self] _, repoRoot, worktrees in
      Task { @MainActor in
        guard let self else { return }
        let key = repoRoot ?? "all"
        self.worktreesByRepo[key] = worktrees
      }
    }

    conn.onWorktreeCreated = { [weak self] _, worktree in
      Task { @MainActor in
        guard let self else { return }
        self.worktreesByRepo[worktree.repoRoot, default: []].append(worktree)
      }
    }

    conn.onWorktreeRemoved = { [weak self] _, worktreeId in
      Task { @MainActor in
        guard let self else { return }
        for key in self.worktreesByRepo.keys {
          self.worktreesByRepo[key]?.removeAll { $0.id == worktreeId }
        }
      }
    }

    conn.onWorktreeStatusChanged = { [weak self] worktreeId, status, repoRoot in
      Task { @MainActor in
        guard let self else { return }
        if let idx = self.worktreesByRepo[repoRoot]?.firstIndex(where: { $0.id == worktreeId }) {
          self.worktreesByRepo[repoRoot]![idx].status = status
        }
      }
    }

    conn.onWorktreeError = { [weak self] _, code, message in
      Task { @MainActor in
        self?.lastServerError = (code: code, message: message)
      }
    }

    conn.onError = { [weak self] code, message, sessionId in
      Task { @MainActor in
        self?.handleError(code, message, sessionId)
      }
    }

    conn.onDisconnected = { [weak self] in
      Task { @MainActor in
        self?.hasReceivedInitialSessionsList = false
      }
    }

    conn.onConnected = { [weak self] in
      Task { @MainActor in
        self?.resubscribeAll()
        self?.refreshCodexModels()
        self?.refreshCodexAccount()
        self?.refreshClaudeModels()
      }
    }

    logger.info("ServerAppState callbacks wired")
    refreshCodexModels()
    refreshCodexAccount()
    refreshClaudeModels()
  }

  // MARK: - Actions

  /// Create a new Codex session
  func createSession(
    cwd: String,
    model: String? = nil,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    initialPrompt: String? = nil
  ) {
    logger.info("Creating Codex session in \(cwd)")
    let autonomy = AutonomyLevel.from(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode)
    pendingCreationAutonomy = autonomy
    pendingNavigationOnCreate = true
    pendingCreateInitialPrompt = initialPrompt
    pendingCreatePromptTargetSessionId = nil
    connection.createSession(
      provider: .codex,
      cwd: cwd,
      model: model,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode
    )
  }

  /// Create a new Claude direct session
  func createClaudeSession(
    cwd: String,
    model: String? = nil,
    permissionMode: String? = nil,
    allowedTools: [String] = [],
    disallowedTools: [String] = [],
    effort: String? = nil,
    initialPrompt: String? = nil
  ) {
    logger.info("Creating Claude session in \(cwd)")
    pendingNavigationOnCreate = true
    pendingCreateInitialPrompt = initialPrompt
    pendingCreatePromptTargetSessionId = nil
    connection.createSession(
      provider: .claude,
      cwd: cwd,
      model: model,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: permissionMode,
      allowedTools: allowedTools,
      disallowedTools: disallowedTools,
      effort: effort
    )
  }

  /// Refresh model options from the server.
  func refreshCodexModels() {
    connection.listModels()
  }

  /// Refresh cached Claude models from the server DB.
  /// Models are populated when Claude sessions are created.
  func refreshClaudeModels() {
    connection.listClaudeModels()
  }

  /// Refresh global Codex account/auth status.
  func refreshCodexAccount(refreshToken: Bool = false) {
    connection.readCodexAccount(refreshToken: refreshToken)
  }

  /// Start ChatGPT browser login for Codex.
  func startCodexChatgptLogin() {
    codexAuthError = nil
    connection.startCodexChatgptLogin()
  }

  /// Cancel an in-progress ChatGPT browser login for Codex.
  func cancelCodexChatgptLogin() {
    guard let loginId = codexActiveLoginId else {
      codexAuthError = "No active sign-in request to cancel."
      return
    }
    connection.cancelCodexChatgptLogin(loginId: loginId)
  }

  /// Log out the current Codex account.
  func logoutCodexAccount() {
    connection.logoutCodexAccount()
  }

  /// Refresh the server-authoritative sessions list.
  func refreshSessionsList() {
    connection.subscribeList()
  }

  private func persistCodexModelsCache(_ models: [ServerCodexModelOption]) {
    if let data = try? JSONEncoder().encode(models) {
      UserDefaults.standard.set(data, forKey: codexModelsCacheKey)
    }
  }

  private func loadSessionsCache() -> SessionsCachePayload? {
    guard let data = UserDefaults.standard.data(forKey: sessionsCacheKey) else {
      return nil
    }

    guard let cached = try? JSONDecoder().decode(SessionsCachePayload.self, from: data) else {
      UserDefaults.standard.removeObject(forKey: sessionsCacheKey)
      return nil
    }

    return cached
  }

  private func persistSessionsCache(_ summaries: [ServerSessionSummary]) {
    let payload = SessionsCachePayload(cachedAt: Date(), summaries: summaries)
    if let data = try? JSONEncoder().encode(payload) {
      UserDefaults.standard.set(data, forKey: sessionsCacheKey)
    }
  }

  private func hydrateConversationCacheIfNeeded(sessionId: String) async {
    let obs = session(sessionId)
    guard !obs.hasConversationSeed, obs.messages.isEmpty else { return }

    guard let cached = await conversationReadModel.loadConversation(
      endpointId: endpointId,
      sessionId: sessionId,
      limit: conversationPageSize
    ) else {
      return
    }

    let cachedMessages = normalizedTranscriptMessages(
      cached.messages,
      sessionId: sessionId,
      source: "cache"
    )
    obs.messages = cachedMessages
    obs.hasLoadedCachedConversation = true
    obs.bumpMessagesRevision()
    obs.totalMessageCount = cached.metadata.totalMessageCount
    obs.oldestLoadedSequence = cachedMessages.first?.sequence ?? cached.metadata.oldestLoadedSequence
    obs.newestLoadedSequence = cachedMessages.last?.sequence ?? cached.metadata.newestLoadedSequence
    obs.hasMoreHistoryBefore = obs.oldestLoadedSequence.map { $0 > 0 } ?? false
    obs.turnDiffs = normalizedTurnDiffs(cached.metadata.turnDiffs, sessionId: sessionId, source: "cache")
    obs.diff = cached.metadata.currentDiff
    obs.plan = cached.metadata.currentPlan
    obs.currentTurnId = cached.metadata.currentTurnId
    obs.tokenUsage = cached.metadata.tokenUsage
    obs.tokenUsageSnapshotKind = cached.metadata.tokenUsageSnapshotKind
    obs.totalTokens = Int((cached.metadata.tokenUsage?.inputTokens ?? 0) + (cached.metadata.tokenUsage?.outputTokens ?? 0))
    obs.inputTokens = cached.metadata.tokenUsage.map { Int($0.inputTokens) }
    obs.outputTokens = cached.metadata.tokenUsage.map { Int($0.outputTokens) }
    obs.cachedTokens = cached.metadata.tokenUsage.map { Int($0.cachedTokens) }
    obs.contextWindow = cached.metadata.tokenUsage.map { Int($0.contextWindow) }

    if let revision = cached.metadata.revision {
      lastRevision[sessionId] = revision
    }

    logger.info(
      "Hydrated cached conversation \(sessionId, privacy: .public) messages=\(cachedMessages.count, privacy: .public) total=\(cached.metadata.totalMessageCount, privacy: .public) revision=\(cached.metadata.revision.map(String.init) ?? "nil", privacy: .public)"
    )
  }

  private func queueConversationSnapshotWrite(
    sessionId: String,
    reason: String,
    mode: ConversationCacheWriteMode
  ) {
    if var existingMode = pendingConversationCacheWriteModes[sessionId] {
      existingMode.merge(with: mode)
      pendingConversationCacheWriteModes[sessionId] = existingMode
    } else {
      pendingConversationCacheWriteModes[sessionId] = mode
    }

    pendingConversationCacheWrites[sessionId]?.cancel()
    pendingConversationCacheWrites[sessionId] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard let self else { return }
      self.pendingConversationCacheWrites.removeValue(forKey: sessionId)
      let writeMode = self.pendingConversationCacheWriteModes.removeValue(forKey: sessionId) ?? mode
      self.persistConversationSnapshot(sessionId: sessionId, reason: reason, mode: writeMode)
    }
  }

  private func flushConversationSnapshotWrite(
    sessionId: String,
    reason: String,
    mode: ConversationCacheWriteMode
  ) {
    let resolvedMode: ConversationCacheWriteMode = {
      if var existingMode = pendingConversationCacheWriteModes.removeValue(forKey: sessionId) {
        existingMode.merge(with: mode)
        return existingMode
      }
      return mode
    }()
    pendingConversationCacheWrites[sessionId]?.cancel()
    pendingConversationCacheWrites.removeValue(forKey: sessionId)
    persistConversationSnapshot(sessionId: sessionId, reason: reason, mode: resolvedMode)
  }

  private func cancelConversationSnapshotWrite(sessionId: String) {
    pendingConversationCacheWrites[sessionId]?.cancel()
    pendingConversationCacheWrites.removeValue(forKey: sessionId)
    pendingConversationCacheWriteModes.removeValue(forKey: sessionId)
  }

  private func persistConversationSnapshot(
    sessionId: String,
    reason: String,
    mode: ConversationCacheWriteMode
  ) {
    let obs = session(sessionId)
    guard
      obs.hasConversationSeed
        || !obs.messages.isEmpty
        || !obs.turnDiffs.isEmpty
        || obs.diff != nil
        || obs.plan != nil
    else {
      return
    }

    let metadata = CachedConversationMetadata(
      sessionId: sessionId,
      revision: lastRevision[sessionId],
      totalMessageCount: max(obs.totalMessageCount, obs.messages.count),
      oldestLoadedSequence: obs.messages.first?.sequence ?? obs.oldestLoadedSequence,
      newestLoadedSequence: obs.messages.last?.sequence ?? obs.newestLoadedSequence,
      currentDiff: obs.diff,
      currentPlan: obs.plan,
      currentTurnId: obs.currentTurnId,
      turnDiffs: obs.turnDiffs,
      tokenUsage: obs.tokenUsage,
      tokenUsageSnapshotKind: obs.tokenUsageSnapshotKind
    )
    let cacheEndpointId = endpointId
    let allMessages = obs.messages

    Task {
      switch mode {
        case .metadataOnly:
          await conversationReadModel.saveMetadata(
            endpointId: cacheEndpointId,
            sessionId: sessionId,
            metadata: metadata
          )
        case .upsertMessages(let messages):
          await conversationReadModel.upsertMessages(
            endpointId: cacheEndpointId,
            sessionId: sessionId,
            metadata: metadata,
            messages: messages
          )
        case .replaceLoadedWindow:
          await conversationReadModel.save(
            endpointId: cacheEndpointId,
            sessionId: sessionId,
            metadata: metadata,
            messages: allMessages
          )
      }
    }

    logger.debug(
      "Persisted cached conversation \(sessionId, privacy: .public) reason=\(reason, privacy: .public) mode=\(mode.debugName, privacy: .public) loaded=\(allMessages.count, privacy: .public) total=\(metadata.totalMessageCount, privacy: .public) revision=\(metadata.revision.map(String.init) ?? "nil", privacy: .public)"
    )
  }

  /// Send a message to a session with optional per-turn overrides, skills, images, and mentions
  @discardableResult
  func sendMessage(
    sessionId: String,
    content: String,
    model: String? = nil,
    effort: String? = nil,
    skills: [ServerSkillInput] = [],
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) -> OutboundSendDisposition {
    logger.info("Sending message to \(sessionId)")
    return connection.sendMessage(
      sessionId: sessionId,
      content: content,
      model: model,
      effort: effort,
      skills: skills,
      images: images,
      mentions: mentions
    )
  }

  /// Request the list of available skills for a session
  func listSkills(sessionId: String) {
    guard shouldRequestCodexConnectorData(sessionId: sessionId) else { return }
    connection.listSkills(sessionId: sessionId)
  }

  /// Resolve the next pending approval request ID for a session.
  /// Session summary is authoritative; do not derive from observable payload state.
  func nextPendingApprovalRequestId(sessionId: String) -> String? {
    guard let summary = sessions.first(where: { $0.id == sessionId }) else { return nil }
    return normalizedApprovalRequestId(summary.pendingApprovalId)
  }

  /// Number of additional approval requests queued behind the active one.
  func queuedApprovalCount(sessionId: String) -> Int {
    queuedApprovalRequests[sessionId]?.count ?? 0
  }

  /// Resolve approval type for a specific pending request.
  func pendingApprovalType(sessionId: String, requestId: String? = nil) -> ServerApprovalType? {
    let targetRequestId = requestId ?? nextPendingApprovalRequestId(sessionId: sessionId)
    guard let targetRequestId else { return nil }

    if let approval = session(sessionId).pendingApproval, approval.id == targetRequestId {
      return approval.type
    }
    return nil
  }

  /// Approve or reject a tool with a specific decision
  @discardableResult
  func approveTool(
    sessionId: String,
    requestId: String,
    decision: String,
    message: String? = nil,
    interrupt: Bool? = nil
  ) -> ApprovalDispatchResult {
    guard let normalizedRequestId = normalizedApprovalRequestId(requestId) else {
      logger.warning("[approval] empty request id in approveTool for \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    let obs = session(sessionId)
    let summaryPendingId = sessions.first(where: { $0.id == sessionId })?.pendingApprovalId
    let obsPendingId = obs.pendingApprovalId
    logger.info(
      "[approval] approveTool: session=\(sessionId) request=\(normalizedRequestId) decision=\(decision) summaryPending=\(summaryPendingId ?? "nil") obsPending=\(obsPendingId ?? "nil")"
    )

    guard hasActivePendingApproval(sessionId: sessionId, requestId: normalizedRequestId) else {
      logger.warning(
        "[approval] stale: request=\(normalizedRequestId) summaryPending=\(summaryPendingId ?? "nil") obsPending=\(obsPendingId ?? "nil")"
      )
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    guard !isApprovalDispatchInFlight(sessionId: sessionId, requestId: normalizedRequestId) else {
      logger.info("[approval] duplicate dispatch for \(normalizedRequestId) in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    markApprovalDispatchInFlight(sessionId: sessionId, requestId: normalizedRequestId)
    logger.info("[approval] dispatching \(normalizedRequestId) in \(sessionId): \(decision)")

    connection.approveTool(
      sessionId: sessionId,
      requestId: normalizedRequestId,
      decision: decision,
      message: message,
      interrupt: interrupt
    )
    return .dispatched
  }

  /// Answer a question
  @discardableResult
  func answerQuestion(
    sessionId: String,
    requestId: String,
    answer: String,
    questionId: String? = nil,
    answers: [String: [String]]? = nil
  ) -> ApprovalDispatchResult {
    guard let normalizedRequestId = normalizedApprovalRequestId(requestId) else {
      logger.warning("Ignoring empty question approval request in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    guard hasActivePendingApproval(sessionId: sessionId, requestId: normalizedRequestId) else {
      logger.warning("Ignoring stale question answer for \(requestId) in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    guard !isApprovalDispatchInFlight(sessionId: sessionId, requestId: normalizedRequestId) else {
      logger.info("Ignoring duplicate question answer for \(normalizedRequestId) in \(sessionId)")
      return .stale(nextPendingRequestId: nextPendingApprovalRequestId(sessionId: sessionId))
    }

    markApprovalDispatchInFlight(sessionId: sessionId, requestId: normalizedRequestId)
    logger.info("Answering question \(normalizedRequestId) in \(sessionId)")
    connection.answerQuestion(
      sessionId: sessionId,
      requestId: normalizedRequestId,
      answer: answer,
      questionId: questionId,
      answers: answers
    )
    return .dispatched
  }

  /// Steer the active turn with additional guidance
  @discardableResult
  func steerTurn(
    sessionId: String,
    content: String,
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) -> OutboundSendDisposition {
    logger.info("Steering turn for \(sessionId)")
    return connection.steerTurn(
      sessionId: sessionId,
      content: content,
      images: images,
      mentions: mentions
    )
  }

  /// Compact (summarize) the conversation context
  func compactContext(sessionId: String) {
    logger.info("Compacting context for \(sessionId)")
    connection.compactContext(sessionId: sessionId)
  }

  /// Undo the last turn (reverts filesystem changes + removes from context)
  func undoLastTurn(sessionId: String) {
    logger.info("Undoing last turn for \(sessionId)")
    connection.undoLastTurn(sessionId: sessionId)
  }

  /// Roll back N turns from context (does NOT revert filesystem changes)
  func rollbackTurns(sessionId: String, numTurns: UInt32) {
    logger.info("Rolling back \(numTurns) turns for \(sessionId)")
    connection.rollbackTurns(sessionId: sessionId, numTurns: numTurns)
  }

  /// Fork a session (creates a new session with conversation history)
  func forkSession(sessionId: String, nthUserMessage: UInt32? = nil) {
    logger.info("Forking session \(sessionId) at turn \(nthUserMessage.map(String.init) ?? "full")")
    session(sessionId).forkInProgress = true
    connection.forkSession(sourceSessionId: sessionId, nthUserMessage: nthUserMessage)
  }

  /// Create a new worktree from the source repository and fork the session into it.
  func forkSessionToWorktree(
    sessionId: String,
    branchName: String,
    baseBranch: String? = nil,
    nthUserMessage: UInt32? = nil
  ) {
    logger.info(
      "Forking session \(sessionId) to worktree branch=\(branchName) base=\(baseBranch ?? "-") at turn \(nthUserMessage.map(String.init) ?? "full")"
    )
    session(sessionId).forkInProgress = true
    connection.forkSessionToWorktree(
      sourceSessionId: sessionId,
      branchName: branchName,
      baseBranch: baseBranch,
      nthUserMessage: nthUserMessage
    )
  }

  /// Fork into an existing tracked worktree.
  func forkSessionToExistingWorktree(
    sessionId: String,
    worktreeId: String,
    nthUserMessage: UInt32? = nil
  ) {
    logger.info(
      "Forking session \(sessionId) to existing worktree=\(worktreeId) at turn \(nthUserMessage.map(String.init) ?? "full")"
    )
    session(sessionId).forkInProgress = true
    connection.forkSessionToExistingWorktree(
      sourceSessionId: sessionId,
      worktreeId: worktreeId,
      nthUserMessage: nthUserMessage
    )
  }

  /// Execute a shell command in a session's working directory (does not trigger AI response)
  func executeShell(sessionId: String, command: String, cwd: String? = nil) {
    logger.info("Executing shell in \(sessionId): \(command)")
    connection.executeShell(sessionId: sessionId, command: command, cwd: cwd)
  }

  /// Cancel an in-flight shell command by request ID
  func cancelShell(sessionId: String, requestId: String) {
    logger.info("Canceling shell command in \(sessionId): \(requestId)")
    connection.cancelShell(sessionId: sessionId, requestId: requestId)
  }

  /// Stop a background task/subagent by task ID
  func stopTask(sessionId: String, taskId: String) {
    logger.info("Stopping task in \(sessionId): \(taskId)")
    connection.stopTask(sessionId: sessionId, taskId: taskId)
  }

  /// Rewind files to their state before a given user message
  func rewindFiles(sessionId: String, userMessageId: String) {
    logger.info("Rewinding files in \(sessionId) to before \(userMessageId)")
    connection.rewindFiles(sessionId: sessionId, userMessageId: userMessageId)
  }

  /// Interrupt a session
  func interruptSession(_ sessionId: String) {
    logger.info("Interrupting session \(sessionId)")
    connection.interruptSession(sessionId)
  }

  /// End a session
  func endSession(_ sessionId: String) {
    logger.info("Ending session \(sessionId)")
    connection.endSession(sessionId)
  }

  /// Resume an ended session
  func resumeSession(_ sessionId: String) {
    logger.info("Resuming session \(sessionId)")
    connLog(.info, category: .resume, "ServerAppState.resumeSession", sessionId: sessionId)
    subscribedSessions.insert(sessionId)
    connection.resumeSession(sessionId)
  }

  /// Take over a passive session (flip to direct mode so we can send messages)
  func takeoverSession(_ sessionId: String) {
    logger.info("Taking over session \(sessionId)")
    subscribedSessions.insert(sessionId)

    // Optimistic: set Direct immediately for instant UI feedback
    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      switch sessions[idx].provider {
        case .codex:
          sessions[idx].codexIntegrationMode = .direct
        case .claude:
          sessions[idx].claudeIntegrationMode = .direct
      }
    }

    connection.takeoverSession(sessionId: sessionId)
  }

  /// Rename a session
  func renameSession(sessionId: String, name: String?) {
    logger.info("Renaming session \(sessionId) to '\(name ?? "(cleared)")'")
    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].customName = name
    }
    connection.renameSession(sessionId: sessionId, name: name)
  }

  /// Update session config (change autonomy level mid-session)
  func updateSessionConfig(sessionId: String, autonomy: AutonomyLevel) {
    logger.info("Updating session config \(sessionId) to \(autonomy.displayName)")
    session(sessionId).autonomy = autonomy
    session(sessionId).autonomyConfiguredOnServer = true
    connection.updateSessionConfig(
      sessionId: sessionId,
      approvalPolicy: autonomy.approvalPolicy,
      sandboxMode: autonomy.sandboxMode
    )
  }

  /// Update permission mode for a Claude direct session
  func updateClaudePermissionMode(sessionId: String, mode: ClaudePermissionMode) {
    logger.info("Updating Claude permission mode \(sessionId) to \(mode.displayName)")
    session(sessionId).permissionMode = mode
    permissionModes[sessionId] = mode.rawValue
    connection.updateSessionConfig(
      sessionId: sessionId,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: mode.rawValue
    )
  }

  /// Update collaboration mode for a Codex direct session (`default` or `plan`).
  func updateCodexCollaborationMode(sessionId: String, mode: CodexCollaborationMode) {
    logger.info("Updating Codex collaboration mode \(sessionId) to \(mode.displayName)")
    session(sessionId).permissionMode = mode.permissionMode
    permissionModes[sessionId] = mode.rawValue
    connection.updateSessionConfig(
      sessionId: sessionId,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: mode.rawValue
    )
  }

  /// Subscribe to a session's updates (called when viewing a session)
  func subscribeToSession(_ sessionId: String) {
    guard !subscribedSessions.contains(sessionId) else { return }
    subscribedSessions.insert(sessionId)

    Task { @MainActor in
      await hydrateConversationCacheIfNeeded(sessionId: sessionId)

      var sinceRev = lastRevision[sessionId]
      var includeSnapshot = !session(sessionId).hasConversationSeed && sinceRev == nil

      do {
        let bootstrap = try await connection.fetchConversationBootstrap(sessionId, limit: conversationPageSize)
        guard subscribedSessions.contains(sessionId) else { return }
        handleConversationBootstrap(bootstrap)
        sinceRev = bootstrap.session.revision
        includeSnapshot = false
      } catch {
        logger.warning("Conversation bootstrap failed for \(sessionId): \(error.localizedDescription)")
      }

      guard subscribedSessions.contains(sessionId) else { return }

      connection.subscribeSession(
        sessionId,
        sinceRevision: sinceRev,
        includeSnapshot: includeSnapshot
      )
      connection.listApprovals(sessionId: sessionId, limit: 200)
      logger.debug(
        "Subscribed to session \(sessionId) (sinceRevision: \(sinceRev.map(String.init) ?? "nil"), includeSnapshot: \(includeSnapshot))"
      )
    }
  }

  func loadOlderMessages(sessionId: String, limit: Int? = nil) {
    let obs = session(sessionId)
    guard !obs.isLoadingOlderMessages else { return }
    guard obs.hasMoreHistoryBefore else { return }
    guard let beforeSequence = obs.oldestLoadedSequence else { return }

    let pageLimit = max(1, limit ?? conversationPageSize)
    obs.isLoadingOlderMessages = true

    Task { @MainActor in
      defer { session(sessionId).isLoadingOlderMessages = false }

      let cachedMessages = await conversationReadModel.loadMessagesBefore(
        endpointId: endpointId,
        sessionId: sessionId,
        beforeSequence: beforeSequence,
        limit: pageLimit
      )
      if !cachedMessages.isEmpty {
        prependConversationMessages(sessionId: sessionId, messages: cachedMessages, source: "cache-history")
        return
      }

      do {
        let page = try await connection.fetchConversationHistory(
          sessionId,
          beforeSequence: beforeSequence,
          limit: pageLimit
        )
        handleConversationHistoryPage(page)
      } catch {
        logger.warning("Failed to load older history for \(sessionId): \(error.localizedDescription)")
      }
    }
  }

  /// Enable or disable automatic mark-read for a subscribed session.
  /// Only enable this while the conversation is visible and following the bottom.
  func setSessionAutoMarkRead(_ sessionId: String, enabled: Bool) {
    if enabled {
      autoMarkReadSessions.insert(sessionId)
      markSessionAsRead(sessionId)
    } else {
      autoMarkReadSessions.remove(sessionId)
    }
  }

  /// Mark a session as read (resets unread count to 0).
  /// Called when the user views a session or while actively viewing during streaming.
  func markSessionAsRead(_ sessionId: String) {
    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }),
          sessions[idx].unreadCount > 0
    else { return }
    sessions[idx].unreadCount = 0
    session(sessionId).unreadCount = 0
    connection.markSessionRead(sessionId: sessionId)
  }

  /// Unsubscribe from a session (called when navigating away)
  func unsubscribeFromSession(_ sessionId: String) {
    subscribedSessions.remove(sessionId)
    autoMarkReadSessions.remove(sessionId)
    connection.unsubscribeSession(sessionId)
    flushConversationSnapshotWrite(
      sessionId: sessionId,
      reason: "unsubscribe",
      mode: .replaceLoadedWindow
    )
    trimInactiveSessionPayload(sessionId, reason: "unsubscribe")
    logger.debug("Unsubscribed from session \(sessionId)")
  }

  /// Called by app lifecycle when memory pressure is signaled.
  /// Trims heavy payloads for sessions that are not currently subscribed.
  func handleMemoryPressure() {
    let inactiveSessionIds = _sessionObservables.keys.filter { !subscribedSessions.contains($0) }
    for sessionId in inactiveSessionIds {
      trimInactiveSessionPayload(sessionId, reason: "memory-pressure")
    }
  }

  /// Check if a session ID belongs to a server-managed session
  func isServerSession(_ sessionId: String) -> Bool {
    sessions.contains { $0.id == sessionId }
  }

  /// Load real permission rules for a session from the provider config
  func loadPermissionRules(sessionId: String, forceRefresh: Bool = false) {
    let obs = session(sessionId)
    guard forceRefresh || !obs.permissionRulesLoading else { return }
    obs.permissionRulesLoading = true

    Task { @MainActor in
      defer { obs.permissionRulesLoading = false }
      do {
        let rules = try await connection.fetchPermissionRules(sessionId)
        obs.permissionRules = rules
      } catch {
        logger.warning("Failed to load permission rules for \(sessionId): \(error)")
      }
    }
  }

  /// Add a permission rule and refresh the rules list
  func addPermissionRule(sessionId: String, pattern: String, behavior: String, scope: String = "project") {
    Task { @MainActor in
      do {
        try await connection.addPermissionRule(
          sessionId: sessionId, pattern: pattern, behavior: behavior, scope: scope
        )
        loadPermissionRules(sessionId: sessionId, forceRefresh: true)
      } catch {
        logger.warning("Failed to add permission rule: \(error)")
      }
    }
  }

  /// Remove a permission rule and refresh the rules list
  func removePermissionRule(sessionId: String, pattern: String, behavior: String, scope: String = "project") {
    Task { @MainActor in
      do {
        try await connection.removePermissionRule(
          sessionId: sessionId, pattern: pattern, behavior: behavior, scope: scope
        )
        loadPermissionRules(sessionId: sessionId, forceRefresh: true)
      } catch {
        logger.warning("Failed to remove permission rule: \(error)")
      }
    }
  }

  /// Load approval history for one session
  func loadApprovalHistory(sessionId: String, limit: Int = 200) {
    connection.listApprovals(sessionId: sessionId, limit: limit)
  }

  /// Load global approval history across all sessions
  func loadGlobalApprovalHistory(limit: Int = 200) {
    connection.listApprovals(sessionId: nil, limit: limit)
  }

  /// Delete one approval history item
  func deleteApproval(approvalId: Int64) {
    connection.deleteApproval(approvalId)
  }

  /// Request subagent tools from the server
  func getSubagentTools(sessionId: String, subagentId: String) {
    connection.getSubagentTools(sessionId: sessionId, subagentId: subagentId)
  }

  /// List MCP tools for a session
  func listMcpTools(sessionId: String) {
    guard shouldRequestCodexConnectorData(sessionId: sessionId) else { return }
    connection.listMcpTools(sessionId: sessionId)
  }

  /// Refresh MCP servers for a session
  func refreshMcpServers(sessionId: String) {
    connection.refreshMcpServers(sessionId: sessionId)
  }

  // MARK: - Reconnection

  /// Re-subscribe to all previously subscribed sessions after reconnect
  private func resubscribeAll() {
    let sessions = subscribedSessions
    subscribedSessions.removeAll()
    logger.info("Re-subscribing to \(sessions.count) session(s) after reconnect")
    for sessionId in sessions {
      subscribeToSession(sessionId)
    }
  }

  // MARK: - Message Handlers

  private func handleSessionsList(_ summaries: [ServerSessionSummary]) {
    logger.info("Received sessions list: \(summaries.count) sessions")
    hasReceivedInitialSessionsList = true
    persistSessionsCache(summaries)

    // Merge: preserve local state for sessions we're actively subscribed to,
    // since the subscription channel (snapshots + deltas) is authoritative.
    let currentById = Dictionary(
      sessions.map { ($0.id, $0) },
      uniquingKeysWith: { _, new in new }
    )
    sessions = summaries.map { summary in
      if subscribedSessions.contains(summary.id),
         let existing = currentById[summary.id]
      {
        return existing
      }
      var s = summary.toSession()
      s.endpointId = endpointId
      s.endpointName = connection.endpointName
      return s
    }

    // Hydrate observables for non-subscribed sessions (subscribed ones get
    // hydrated via snapshot/delta, so skip them to avoid overwriting richer state)
    for sess in sessions where !subscribedSessions.contains(sess.id) {
      hydrateObservable(session(sess.id), from: sess)
    }

    for summary in summaries {
      if summary.provider == .codex {
        setConfigCache(sessionId: summary.id, approvalPolicy: summary.approvalPolicy, sandboxMode: summary.sandboxMode)
        session(summary.id).autonomy = AutonomyLevel.from(
          approvalPolicy: summary.approvalPolicy,
          sandboxMode: summary.sandboxMode
        )
        session(summary.id).autonomyConfiguredOnServer = isAutonomyConfigured(
          approvalPolicy: summary.approvalPolicy,
          sandboxMode: summary.sandboxMode
        )
      } else if summary.provider == .claude {
        if let pm = summary.permissionMode {
          permissionModes[summary.id] = pm
        } else {
          permissionModes.removeValue(forKey: summary.id)
        }
        session(summary.id).permissionMode =
          ClaudePermissionMode(rawValue: permissionModes[summary.id] ?? "default") ?? .default
      }
    }

    // Clean up observables for sessions that disappeared from the server
    let liveIds = Set(summaries.map(\.id))
    let staleIds = _sessionObservables.keys.filter { !liveIds.contains($0) }
    for id in staleIds {
      cancelConversationSnapshotWrite(sessionId: id)
      _sessionObservables.removeValue(forKey: id)
    }

    for sessionId in autoMarkReadSessions {
      markSessionAsRead(sessionId)
    }

    refreshWorktreesForActiveSessions()
  }

  private func handleApprovalsList(sessionId: String?, approvals: [ServerApprovalHistoryItem]) {
    if let sessionId {
      session(sessionId).approvalHistory = approvals
    } else {
      globalApprovalHistory = approvals
    }
  }

  private func handleApprovalDeleted(approvalId: Int64) {
    globalApprovalHistory.removeAll { $0.id == approvalId }
    for (id, obs) in _sessionObservables {
      if obs.approvalHistory.contains(where: { $0.id == approvalId }) {
        _sessionObservables[id]?.approvalHistory.removeAll { $0.id == approvalId }
      }
    }
  }

  private func handleConversationBootstrap(_ bootstrap: ServerConversationBootstrap) {
    let state = bootstrap.session
    let obs = session(state.id)
    let existingMessages = obs.messages
    let incomingMessages = normalizedTranscriptMessages(
      state.messages.map { $0.toTranscriptMessage() },
      sessionId: state.id,
      source: "conversation-bootstrap"
    )

    let shouldDiscardExisting: Bool = {
      if Int(bootstrap.totalMessageCount) < existingMessages.count {
        return true
      }
      if let existingNewest = existingMessages.last?.sequence,
         let bootstrapNewest = bootstrap.newestSequence,
         bootstrapNewest < existingNewest
      {
        return true
      }
      return false
    }()

    let preservedOlderMessages: [TranscriptMessage]
    if shouldDiscardExisting {
      preservedOlderMessages = []
    } else if let incomingOldest = incomingMessages.first?.sequence {
      preservedOlderMessages = existingMessages.filter { ($0.sequence ?? UInt64.max) < incomingOldest }
    } else {
      preservedOlderMessages = existingMessages
    }

    handleSessionSnapshot(state)

    if !preservedOlderMessages.isEmpty {
      obs.messages = normalizedTranscriptMessages(
        preservedOlderMessages + obs.messages,
        sessionId: state.id,
        source: "conversation-bootstrap-merge"
      )
      obs.bumpMessagesRevision()
    }

    obs.totalMessageCount = Int(bootstrap.totalMessageCount)
    obs.oldestLoadedSequence = obs.messages.first?.sequence ?? bootstrap.oldestSequence
    obs.newestLoadedSequence = obs.messages.last?.sequence ?? bootstrap.newestSequence
    obs.hasMoreHistoryBefore = obs.oldestLoadedSequence.map { $0 > 0 } ?? bootstrap.hasMoreBefore

    flushConversationSnapshotWrite(
      sessionId: state.id,
      reason: "conversation-bootstrap",
      mode: .replaceLoadedWindow
    )
  }

  private func prependConversationMessages(
    sessionId: String,
    messages incoming: [TranscriptMessage],
    totalMessageCount: Int? = nil,
    oldestSequence: UInt64? = nil,
    newestSequence: UInt64? = nil,
    hasMoreBefore: Bool? = nil,
    source: String
  ) {
    guard !incoming.isEmpty else {
      let obs = session(sessionId)
      if let totalMessageCount {
        obs.totalMessageCount = max(totalMessageCount, obs.messages.count)
      }
      if let oldestSequence {
        obs.oldestLoadedSequence = oldestSequence
      }
      if let newestSequence {
        obs.newestLoadedSequence = newestSequence
      }
      if let hasMoreBefore {
        obs.hasMoreHistoryBefore = hasMoreBefore
      }
      return
    }

    let obs = session(sessionId)
    let mergedMessages = normalizedTranscriptMessages(
      incoming + obs.messages,
      sessionId: sessionId,
      source: source
    )
    guard mergedMessages != obs.messages else { return }

    obs.messages = mergedMessages
    obs.totalMessageCount = max(totalMessageCount ?? obs.totalMessageCount, mergedMessages.count)
    obs.oldestLoadedSequence = mergedMessages.first?.sequence ?? oldestSequence ?? obs.oldestLoadedSequence
    obs.newestLoadedSequence = mergedMessages.last?.sequence ?? newestSequence ?? obs.newestLoadedSequence
    obs.hasMoreHistoryBefore = obs.oldestLoadedSequence.map { $0 > 0 } ?? hasMoreBefore ?? false
    obs.bumpMessagesRevision()
    if !source.hasPrefix("cache") {
      queueConversationSnapshotWrite(
        sessionId: sessionId,
        reason: "history-page",
        mode: .upsertMessages(incoming)
      )
    }
  }

  private func handleConversationHistoryPage(_ page: ServerConversationHistoryPage) {
    let incoming = normalizedTranscriptMessages(
      page.messages.map { $0.toTranscriptMessage() },
      sessionId: page.sessionId,
      source: "history-page"
    )
    prependConversationMessages(
      sessionId: page.sessionId,
      messages: incoming,
      totalMessageCount: Int(page.totalMessageCount),
      oldestSequence: page.oldestSequence,
      newestSequence: page.newestSequence,
      hasMoreBefore: page.hasMoreBefore,
      source: "history-page-merge"
    )
  }

  private func handleSessionSnapshot(_ state: ServerSessionState) {
    logger.info("Received snapshot for \(state.id): \(state.messages.count) messages")
    let wasKnownSession = sessions.contains(where: { $0.id == state.id })

    // Track revision for incremental reconnection
    if let rev = state.revision {
      lastRevision[state.id] = rev
    }

    // Mark as subscribed (server pre-subscribes creator on CreateSession)
    subscribedSessions.insert(state.id)

    // Update session in list
    var sess = state.toSession()
    sess.customName = state.customName
    updateSessionInList(sess)

    // Hydrate observable with session-level fields
    let obs = session(state.id)
    hydrateObservable(obs, from: sess)
    let snapshotMessages = state.messages.map { $0.toTranscriptMessage() }
    obs.messages = normalizedTranscriptMessages(snapshotMessages, sessionId: state.id, source: "snapshot")
    obs.totalMessageCount = Int(state.totalMessageCount ?? UInt64(state.messages.count))
    obs.oldestLoadedSequence = obs.messages.first?.sequence ?? state.oldestSequence
    obs.newestLoadedSequence = obs.messages.last?.sequence ?? state.newestSequence
    obs.hasMoreHistoryBefore = state.hasMoreBefore ?? (obs.oldestLoadedSequence.map { $0 > 0 } ?? false)
    obs.hasReceivedSnapshot = true
    obs.hasLoadedCachedConversation = false
    obs.bumpMessagesRevision()

    if let approval = state.pendingApproval {
      obs.pendingApproval = approval
      if let normalized = normalizedApprovalRequestId(approval.id) {
        queuedApprovalRequests[state.id]?.removeValue(forKey: normalized)
      }
    } else {
      obs.pendingApproval = nil
      if state.pendingApprovalId == nil {
        queuedApprovalRequests[state.id] = nil
      }
    }
    if let version = state.approvalVersion {
      obs.approvalVersion = version
    }
    reconcileApprovalDispatchState(
      sessionId: state.id,
      activeRequestId: state.pendingApprovalId
    )

    obs.tokenUsage = state.tokenUsage
    obs.tokenUsageSnapshotKind = state.tokenUsageSnapshotKind

    if state.provider == .codex || state.claudeIntegrationMode == .direct {
      setConfigCache(sessionId: state.id, approvalPolicy: state.approvalPolicy, sandboxMode: state.sandboxMode)
      obs.autonomy = AutonomyLevel.from(
        approvalPolicy: state.approvalPolicy,
        sandboxMode: state.sandboxMode
      )
      obs.autonomyConfiguredOnServer = isAutonomyConfigured(
        approvalPolicy: state.approvalPolicy,
        sandboxMode: state.sandboxMode
      )
    }

    // Hydrate permission mode from snapshot for Claude direct sessions.
    if state.provider == .claude, state.claudeIntegrationMode == .direct {
      if let pm = state.permissionMode {
        permissionModes[state.id] = pm
      }
      obs.permissionMode = ClaudePermissionMode(rawValue: permissionModes[state.id] ?? "default") ?? .default
    }

    if let diff = state.currentDiff {
      obs.diff = diff
    }
    if let plan = state.currentPlan {
      obs.plan = plan
    }

    if let sourceId = state.forkedFromSessionId {
      obs.forkedFrom = sourceId
    }

    // Turn tracking
    obs.currentTurnId = state.currentTurnId
    obs.turnCount = state.turnCount
    obs.turnDiffs = normalizedTurnDiffs(state.turnDiffs, sessionId: state.id, source: "snapshot")

    // Subagents
    obs.subagents = state.subagents

    // Navigate to newly created session on snapshot (arrives before SessionCreated,
    // so the view gets the full state including integration mode immediately).
    if pendingCreateInitialPrompt != nil,
       pendingCreatePromptTargetSessionId == nil,
       !wasKnownSession
    {
      pendingCreatePromptTargetSessionId = state.id
    }

    if pendingNavigationOnCreate {
      pendingNavigationOnCreate = false
      Platform.services.playHaptic(.success)
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": SessionRef(endpointId: endpointId, sessionId: state.id).scopedID]
      )
    }

    if autoMarkReadSessions.contains(state.id) {
      markSessionAsRead(state.id)
    }

    flushConversationSnapshotWrite(
      sessionId: state.id,
      reason: "snapshot",
      mode: .replaceLoadedWindow
    )
  }

  private func handleSessionDelta(_ sessionId: String, _ changes: ServerStateChanges) {
    logger.debug("Session delta for \(sessionId)")

    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    var sess = sessions[idx]
    let obs = session(sessionId)
    let hadPendingApproval = obs.pendingApproval != nil

    if let status = changes.status {
      let mapped: Session.SessionStatus = status == .active ? .active : .ended
      sess.status = mapped
      obs.status = mapped
    }
    if let workStatus = changes.workStatus {
      let mapped = workStatus.toSessionWorkStatus()
      let attention = workStatus.toAttentionReason()
      sess.workStatus = mapped
      sess.attentionReason = attention
      obs.workStatus = mapped
      obs.attentionReason = attention

      // Clear prompt suggestions when a new turn starts
      if mapped == .working {
        obs.promptSuggestions.removeAll()
        obs.rateLimitInfo = nil
      }
    }
    if let approvalOuter = changes.pendingApproval {
      let incomingVersion = changes.approvalVersion ?? 0
      let isStale = incomingVersion > 0 && incomingVersion < obs.approvalVersion

      if isStale {
        logger
          .debug(
            "[approval] ignored stale delta v\(incomingVersion) (current: \(obs.approvalVersion)) for \(sessionId)"
          )
      } else {
        if incomingVersion > 0 {
          obs.approvalVersion = incomingVersion
        }

        if let approval = approvalOuter {
          obs.pendingApproval = approval
          if let normalized = normalizedApprovalRequestId(approval.id) {
            queuedApprovalRequests[sessionId]?.removeValue(forKey: normalized)
          }
          let toolName = approval.toolNameForDisplay
          let toolInput = approval.toolInputForDisplay
          let permDetail = approval.preview?.compact
            ?? String.shellCommandDisplay(from: approval.command)
            ?? approval.command
          let question = approval.questionPrompts.first?.question ?? approval.question
          let attention: Session.AttentionReason = approval.type == .question ? .awaitingQuestion : .awaitingPermission

          sess.pendingApprovalId = approval.id
          sess.pendingToolName = toolName
          sess.pendingToolInput = toolInput
          sess.pendingPermissionDetail = permDetail
          sess.pendingQuestion = question
          sess.attentionReason = attention
          sess.workStatus = .permission

          obs.pendingApprovalId = approval.id
          obs.pendingToolName = toolName
          obs.pendingToolInput = toolInput
          obs.pendingPermissionDetail = permDetail
          obs.pendingQuestion = question
          obs.attentionReason = attention
          obs.workStatus = .permission
        } else {
          obs.pendingApproval = nil
          queuedApprovalRequests[sessionId] = nil
          sess.pendingApprovalId = nil
          sess.pendingToolName = nil
          sess.pendingToolInput = nil
          sess.pendingPermissionDetail = nil
          sess.pendingQuestion = nil

          obs.pendingApprovalId = nil
          obs.pendingToolName = nil
          obs.pendingToolInput = nil
          obs.pendingPermissionDetail = nil
          obs.pendingQuestion = nil
        }
      }
    }
    if let usage = changes.tokenUsage {
      obs.tokenUsage = usage
      let total = Int(usage.inputTokens + usage.outputTokens)
      let input = Int(usage.inputTokens)
      let output = Int(usage.outputTokens)
      let cached = Int(usage.cachedTokens)
      let window = Int(usage.contextWindow)
      sess.totalTokens = total
      sess.inputTokens = input
      sess.outputTokens = output
      sess.cachedTokens = cached
      sess.contextWindow = window
      obs.totalTokens = total
      obs.inputTokens = input
      obs.outputTokens = output
      obs.cachedTokens = cached
      obs.contextWindow = window
    }
    if let snapshotKind = changes.tokenUsageSnapshotKind {
      obs.tokenUsageSnapshotKind = snapshotKind
      sess.tokenUsageSnapshotKind = snapshotKind
    }
    if let diffOuter = changes.currentDiff {
      if let diff = diffOuter {
        obs.diff = diff
        sess.currentDiff = diff
      } else {
        obs.diff = nil
        sess.currentDiff = nil
      }
    }
    if let planOuter = changes.currentPlan {
      if let plan = planOuter {
        obs.plan = plan
      } else {
        obs.plan = nil
      }
    }
    if let nameOuter = changes.customName {
      let val = nameOuter
      sess.customName = val
      obs.customName = val
    }
    if let summaryOuter = changes.summary {
      let val = summaryOuter
      sess.summary = val
      obs.summary = val
    }
    if let firstPromptOuter = changes.firstPrompt {
      let val = firstPromptOuter
      sess.firstPrompt = val
      obs.firstPrompt = val
    }
    if let lastMessageOuter = changes.lastMessage {
      let val = lastMessageOuter
      sess.lastMessage = val
      obs.lastMessage = val
    }
    if let modeOuter = changes.codexIntegrationMode {
      let val = modeOuter.flatMap { $0.toSessionMode() }
      sess.codexIntegrationMode = val
      obs.codexIntegrationMode = val
    }
    if let modeOuter = changes.claudeIntegrationMode {
      let val = modeOuter.flatMap { $0.toSessionMode() }
      sess.claudeIntegrationMode = val
      obs.claudeIntegrationMode = val
    }
    if let approvalOuter = changes.approvalPolicy {
      setConfigCache(
        sessionId: sessionId,
        approvalPolicy: approvalOuter,
        sandboxMode: sandboxModes[sessionId]
      )
    }
    if let sandboxOuter = changes.sandboxMode {
      setConfigCache(
        sessionId: sessionId,
        approvalPolicy: approvalPolicies[sessionId],
        sandboxMode: sandboxOuter
      )
    }
    if changes.approvalPolicy != nil || changes.sandboxMode != nil {
      let approval = approvalPolicies[sessionId]
      let sandbox = sandboxModes[sessionId]
      obs.autonomy = AutonomyLevel.from(approvalPolicy: approval, sandboxMode: sandbox)
      obs.autonomyConfiguredOnServer = isAutonomyConfigured(
        approvalPolicy: approval,
        sandboxMode: sandbox
      )
    }
    if let turnIdOuter = changes.currentTurnId {
      if let turnId = turnIdOuter {
        obs.currentTurnId = turnId
      } else {
        obs.currentTurnId = nil
      }
    }
    if let count = changes.turnCount {
      obs.turnCount = count
    }
    if let branchOuter = changes.gitBranch {
      sess.branch = branchOuter
      obs.branch = branchOuter
    }
    if let shaOuter = changes.gitSha {
      sess.gitSha = shaOuter
      obs.gitSha = shaOuter
    }
    if let cwdOuter = changes.currentCwd {
      sess.currentCwd = cwdOuter
      obs.currentCwd = cwdOuter
    }
    if let modelOuter = changes.model {
      sess.model = modelOuter
      obs.model = modelOuter
    }
    if let effortOuter = changes.effort {
      sess.effort = effortOuter
      obs.effort = effortOuter
    }
    if let pmOuter = changes.permissionMode {
      if let pm = pmOuter {
        permissionModes[sessionId] = pm
      } else {
        permissionModes.removeValue(forKey: sessionId)
      }
      obs.permissionMode = ClaudePermissionMode(rawValue: permissionModes[sessionId] ?? "default") ?? .default
    }
    if let lastActivity = changes.lastActivityAt {
      let stripped = lastActivity.hasSuffix("Z") ? String(lastActivity.dropLast()) : lastActivity
      if let secs = TimeInterval(stripped) {
        let date = Date(timeIntervalSince1970: secs)
        sess.lastActivityAt = date
        obs.lastActivityAt = date
      }
    }
    if let repoRootOuter = changes.repositoryRoot {
      sess.repositoryRoot = repoRootOuter
      obs.repositoryRoot = repoRootOuter
    }
    if let isWt = changes.isWorktree {
      sess.isWorktree = isWt
      obs.isWorktree = isWt
    }
    if let count = changes.unreadCount {
      sess.unreadCount = count
      obs.unreadCount = count
    }

    // Stale approval scrub:
    // External approval decisions (from CLI/hooks) can clear pending IDs through
    // session summary/work status deltas without emitting a `pending_approval` field.
    // If summary is no longer blocked and has no pending approval id, drop any
    // lingering observable approval payload so inline takeover cards disappear.
    let summaryStillBlocked = sess.attentionReason == .awaitingPermission
      || sess.attentionReason == .awaitingQuestion
      || sess.workStatus == .permission
    if changes.pendingApproval == nil, !summaryStillBlocked {
      sess.pendingApprovalId = nil
      sess.pendingToolName = nil
      sess.pendingToolInput = nil
      sess.pendingPermissionDetail = nil
      sess.pendingQuestion = nil

      obs.pendingApproval = nil
      obs.pendingApprovalId = nil
      obs.pendingToolName = nil
      obs.pendingToolInput = nil
      obs.pendingPermissionDetail = nil
      obs.pendingQuestion = nil
      queuedApprovalRequests[sessionId] = nil
    }

    sessions[idx] = sess
    if autoMarkReadSessions.contains(sessionId), sess.unreadCount > 0 {
      markSessionAsRead(sessionId)
    }
    reconcileApprovalDispatchState(
      sessionId: sessionId,
      activeRequestId: sess.pendingApprovalId
    )

    // Keep approval history in sync when approval resolves without a manual UI action
    let hasPendingApproval = obs.pendingApproval != nil
    if hadPendingApproval, !hasPendingApproval {
      refreshApprovalHistory(sessionId: sessionId)
    }

    queueConversationSnapshotWrite(sessionId: sessionId, reason: "session-delta", mode: .metadataOnly)
  }

  private func refreshApprovalHistory(sessionId: String) {
    connection.listApprovals(sessionId: sessionId, limit: 200)
    connection.listApprovals(sessionId: nil, limit: 200)
  }

  private func hasActivePendingApproval(sessionId: String, requestId: String) -> Bool {
    guard let normalizedRequestId = normalizedApprovalRequestId(requestId) else { return false }
    if let summary = sessions.first(where: { $0.id == sessionId }) {
      // Session summary is authoritative when present.
      if normalizedApprovalRequestId(summary.pendingApprovalId) == normalizedRequestId {
        return true
      }
      // Summary exists but has no pending ID — fall through to observable
      // in case the ApprovalRequested arrived but no SessionDelta followed yet.
      if summary.pendingApprovalId == nil {
        let obs = session(sessionId)
        if normalizedApprovalRequestId(obs.pendingApprovalId) == normalizedRequestId {
          return true
        }
        if let pending = obs.pendingApproval,
           normalizedApprovalRequestId(pending.id) == normalizedRequestId
        {
          return true
        }
      }
      return false
    }
    // No summary found — fall back to observable entirely.
    let obs = session(sessionId)
    if normalizedApprovalRequestId(obs.pendingApprovalId) == normalizedRequestId {
      return true
    }
    if let pending = obs.pendingApproval,
       normalizedApprovalRequestId(pending.id) == normalizedRequestId
    {
      return true
    }
    return false
  }

  private func mergeMessage(_ existing: TranscriptMessage, with incoming: TranscriptMessage) -> TranscriptMessage {
    let mergedThinking: String? = {
      if let incomingThinking = incoming.thinking,
         !incomingThinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return incomingThinking
      }
      return existing.thinking
    }()

    return TranscriptMessage(
      id: incoming.id,
      sequence: incoming.sequence ?? existing.sequence,
      type: incoming.type,
      content: incoming.content.isEmpty ? existing.content : incoming.content,
      timestamp: incoming.timestamp,
      toolName: incoming.toolName ?? existing.toolName,
      toolInput: incoming.toolInput ?? existing.toolInput,
      rawToolInput: incoming.rawToolInput ?? existing.rawToolInput,
      toolOutput: incoming.toolOutput ?? existing.toolOutput,
      toolDuration: incoming.toolDuration ?? existing.toolDuration,
      inputTokens: incoming.inputTokens ?? existing.inputTokens,
      outputTokens: incoming.outputTokens ?? existing.outputTokens,
      isError: incoming.isError || existing.isError,
      isInProgress: incoming.isInProgress,
      images: incoming.images.isEmpty ? existing.images : incoming.images,
      thinking: mergedThinking
    )
  }

  private func withMessageID(_ message: TranscriptMessage, id: String) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: message.sequence,
      type: message.type,
      content: message.content,
      timestamp: message.timestamp,
      toolName: message.toolName,
      toolInput: message.toolInput,
      rawToolInput: message.rawToolInput,
      toolOutput: message.toolOutput,
      toolDuration: message.toolDuration,
      inputTokens: message.inputTokens,
      outputTokens: message.outputTokens,
      isError: message.isError,
      isInProgress: message.isInProgress,
      images: message.images,
      thinking: message.thinking
    )
  }

  private func syntheticMessageID(
    sessionId: String,
    source: String,
    index: Int,
    message: TranscriptMessage
  ) -> String {
    let millis = Int(message.timestamp.timeIntervalSince1970 * 1_000)
    let tool = message.toolName ?? "-"
    return "synthetic:\(sessionId):\(source):\(message.type.rawValue):\(millis):\(index):\(tool):\(message.content.count)"
  }

  private func normalizedTranscriptMessages(
    _ incoming: [TranscriptMessage],
    sessionId: String,
    source: String
  ) -> [TranscriptMessage] {
    guard !incoming.isEmpty else { return [] }

    var normalized: [TranscriptMessage] = []
    normalized.reserveCapacity(incoming.count)
    var indexByID: [String: Int] = [:]
    var syntheticCount = 0
    var duplicateCount = 0

    for (index, raw) in incoming.enumerated() {
      let trimmedID = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
      let messageID: String
      if trimmedID.isEmpty {
        messageID = syntheticMessageID(sessionId: sessionId, source: source, index: index, message: raw)
        syntheticCount += 1
      } else {
        messageID = trimmedID
      }

      let message = messageID == raw.id ? raw : withMessageID(raw, id: messageID)

      if let existingIndex = indexByID[messageID] {
        normalized[existingIndex] = mergeMessage(normalized[existingIndex], with: message)
        duplicateCount += 1
      } else {
        indexByID[messageID] = normalized.count
        normalized.append(message)
      }
    }

    if syntheticCount > 0 || duplicateCount > 0 {
      logger.warning(
        "Normalized messages for \(sessionId, privacy: .public) source=\(source, privacy: .public) in=\(incoming.count, privacy: .public) out=\(normalized.count, privacy: .public) synthetic=\(syntheticCount, privacy: .public) duplicates=\(duplicateCount, privacy: .public)"
      )
    }

    return normalized
  }

  private func normalizedTranscriptMessage(
    _ incoming: TranscriptMessage,
    sessionId: String,
    source: String
  ) -> TranscriptMessage? {
    normalizedTranscriptMessages([incoming], sessionId: sessionId, source: source).first
  }

  private func normalizedTurnDiffs(
    _ incoming: [ServerTurnDiff],
    sessionId: String,
    source: String
  ) -> [ServerTurnDiff] {
    guard !incoming.isEmpty else { return [] }

    var byTurnId: [String: ServerTurnDiff] = [:]
    var orderedTurnIds: [String] = []
    byTurnId.reserveCapacity(incoming.count)
    orderedTurnIds.reserveCapacity(incoming.count)
    var duplicateCount = 0

    for turnDiff in incoming {
      if byTurnId[turnDiff.turnId] == nil {
        orderedTurnIds.append(turnDiff.turnId)
      } else {
        duplicateCount += 1
      }
      byTurnId[turnDiff.turnId] = turnDiff
    }

    let normalized = orderedTurnIds.compactMap { byTurnId[$0] }
    if duplicateCount > 0 {
      logger.warning(
        "Normalized turn diffs for \(sessionId, privacy: .public) source=\(source, privacy: .public) in=\(incoming.count, privacy: .public) out=\(normalized.count, privacy: .public) duplicates=\(duplicateCount, privacy: .public)"
      )
    }
    return normalized
  }

  private func handleMessageAppended(_ sessionId: String, _ message: ServerMessage) {
    logger.debug("Message event for \(sessionId): id=\(message.id, privacy: .public) type=\(message.type.rawValue)")
    guard let transcriptMsg = normalizedTranscriptMessages(
      [message.toTranscriptMessage()],
      sessionId: sessionId,
      source: "append"
    ).first
    else { return }

    let obs = session(sessionId)
    var messages = obs.messages
    let beforeCount = messages.count
    let persistedMessage: TranscriptMessage

    let mergeAction: String
    if let idx = messages.firstIndex(where: { $0.id == transcriptMsg.id }) {
      messages[idx] = mergeMessage(messages[idx], with: transcriptMsg)
      mergeAction = "merged"
      obs.messages = messages
      obs.bumpMessagesRevision(.upsert(messages[idx]))
      persistedMessage = messages[idx]
    } else {
      messages.append(transcriptMsg)
      mergeAction = "appended"
      obs.messages = messages
      obs.bumpMessagesRevision(.upsert(transcriptMsg))
      persistedMessage = transcriptMsg
    }
    logger.debug(
      "Message \(mergeAction, privacy: .public) for \(sessionId): id=\(transcriptMsg.id, privacy: .public) before=\(beforeCount, privacy: .public) after=\(obs.messages.count, privacy: .public)"
    )
    if mergeAction == "appended" {
      obs.totalMessageCount = max(obs.totalMessageCount + 1, obs.messages.count)
    } else {
      obs.totalMessageCount = max(obs.totalMessageCount, obs.messages.count)
    }
    obs.oldestLoadedSequence = obs.messages.first?.sequence ?? obs.oldestLoadedSequence
    obs.newestLoadedSequence = max(obs.newestLoadedSequence ?? 0, transcriptMsg.sequence ?? 0)
    if obs.newestLoadedSequence == 0, transcriptMsg.sequence == nil {
      obs.newestLoadedSequence = obs.messages.last?.sequence
    }
    obs.hasMoreHistoryBefore = obs.oldestLoadedSequence.map { $0 > 0 } ?? false
    queueConversationSnapshotWrite(
      sessionId: sessionId,
      reason: "message-appended",
      mode: .upsertMessages([persistedMessage])
    )

    // Auto mark-read only when the conversation is actually visible and following the bottom.
    if autoMarkReadSessions.contains(sessionId) {
      markSessionAsRead(sessionId)
    }
  }

  private func handleMessageUpdated(_ sessionId: String, _ messageId: String, _ changes: ServerMessageChanges) {
    logger.debug("Message updated in \(sessionId): \(messageId)")

    let obs = session(sessionId)
    var messages = obs.messages
    let normalizedMessageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !normalizedMessageId.isEmpty else {
      logger.warning("Message update arrived with empty id in \(sessionId)")
      return
    }

    guard let idx = messages.firstIndex(where: { $0.id == normalizedMessageId }) else {
      guard let content = changes.content else { return }
      let fallback = TranscriptMessage(
        id: normalizedMessageId,
        type: .assistant,
        content: content,
        timestamp: Date(),
        toolName: nil,
        toolInput: nil,
        rawToolInput: nil,
        toolOutput: changes.toolOutput,
        toolDuration: changes.durationMs.map { Double($0) / 1_000.0 },
        inputTokens: nil,
        outputTokens: nil,
        isError: changes.isError ?? false,
        isInProgress: changes.isInProgress ?? false
      )
      guard let normalizedFallback = normalizedTranscriptMessage(
        fallback,
        sessionId: sessionId,
        source: "update-fallback"
      ) else { return }
      messages.append(normalizedFallback)
      obs.messages = messages
      obs.totalMessageCount = max(obs.totalMessageCount + 1, obs.messages.count)
      obs.oldestLoadedSequence = obs.messages.first?.sequence ?? obs.oldestLoadedSequence
      obs.newestLoadedSequence = obs.messages.last?.sequence ?? obs.newestLoadedSequence
      obs.hasMoreHistoryBefore = obs.oldestLoadedSequence.map { $0 > 0 } ?? false
      obs.bumpMessagesRevision(.upsert(normalizedFallback))
      logger.warning("Message update arrived before create; upserted \(normalizedMessageId) in \(sessionId)")
      queueConversationSnapshotWrite(
        sessionId: sessionId,
        reason: "message-updated",
        mode: .upsertMessages([normalizedFallback])
      )
      return
    }

    var msg = messages[idx]
    if let content = changes.content {
      msg = TranscriptMessage(
        id: msg.id,
        type: msg.type,
        content: content,
        timestamp: msg.timestamp,
        toolName: msg.toolName,
        toolInput: msg.toolInput,
        rawToolInput: msg.rawToolInput,
        toolOutput: changes.toolOutput ?? msg.toolOutput,
        toolDuration: changes.durationMs.map { Double($0) / 1_000.0 } ?? msg.toolDuration,
        inputTokens: msg.inputTokens,
        outputTokens: msg.outputTokens,
        isError: changes.isError ?? msg.isError,
        isInProgress: changes.isInProgress ?? msg.isInProgress,
        images: msg.images,
        thinking: msg.thinking
      )
    } else {
      if let output = changes.toolOutput {
        msg.toolOutput = output
      }
      if let durationMs = changes.durationMs {
        msg.toolDuration = Double(durationMs) / 1_000.0
      }
      if let isError = changes.isError {
        msg.isError = isError
      }
      if let isInProgress = changes.isInProgress {
        msg.isInProgress = isInProgress
      }
    }
    messages[idx] = msg
    obs.messages = messages
    obs.totalMessageCount = max(obs.totalMessageCount, obs.messages.count)
    obs.oldestLoadedSequence = obs.messages.first?.sequence ?? obs.oldestLoadedSequence
    obs.newestLoadedSequence = obs.messages.last?.sequence ?? obs.newestLoadedSequence
    obs.hasMoreHistoryBefore = obs.oldestLoadedSequence.map { $0 > 0 } ?? false
    obs.bumpMessagesRevision(.upsert(msg))
    queueConversationSnapshotWrite(
      sessionId: sessionId,
      reason: "message-updated",
      mode: .upsertMessages([msg])
    )
  }

  private func handleApprovalRequested(
    _ sessionId: String,
    _ request: ServerApprovalRequest,
    approvalVersion: UInt64?
  ) {
    let obs = session(sessionId)
    guard let normalizedRequestId = normalizedApprovalRequestId(request.id) else {
      logger.warning("[approval] ignoring request with empty request id for session \(sessionId)")
      return
    }
    let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId })
    let sessionPendingId = sessionIndex.flatMap { index in
      normalizedApprovalRequestId(sessions[index].pendingApprovalId)
    }
    let currentActiveRequestId = sessionPendingId

    // Version gating: discard events older than what we already have
    if let version = approvalVersion, version <= obs.approvalVersion {
      logger.debug("[approval] ignored stale event v\(version) (current: \(obs.approvalVersion)) for \(sessionId)")
      return
    }

    logger
      .info(
        "[approval] received: session=\(sessionId) request=\(request.id) version=\(approvalVersion.map(String.init) ?? "nil") type=\(request.type.rawValue)"
      )

    if let version = approvalVersion {
      obs.approvalVersion = version
    }

    if let currentActiveRequestId, currentActiveRequestId != normalizedRequestId {
      logger.info(
        "[approval] queued request observed: session=\(sessionId) active=\(currentActiveRequestId) queued=\(normalizedRequestId)"
      )
      var queued = queuedApprovalRequests[sessionId] ?? [:]
      queued[normalizedRequestId] = request
      queuedApprovalRequests[sessionId] = queued
      reconcileApprovalDispatchState(
        sessionId: sessionId,
        activeRequestId: currentActiveRequestId
      )
      return
    }

    queuedApprovalRequests[sessionId]?.removeValue(forKey: normalizedRequestId)

    obs.pendingApproval = request

    let toolName = request.toolNameForDisplay
    let toolInput = request.toolInputForDisplay
    let permDetail = request.preview?.compact
      ?? String.shellCommandDisplay(from: request.command)
      ?? request.command
    let question = request.questionPrompts.first?.question ?? request.question
    let attention: Session.AttentionReason = request.type == .question ? .awaitingQuestion : .awaitingPermission

    obs.pendingApprovalId = normalizedRequestId
    obs.pendingToolName = toolName
    obs.pendingToolInput = toolInput
    obs.pendingPermissionDetail = permDetail
    obs.pendingQuestion = question
    obs.attentionReason = attention
    obs.workStatus = .permission

    if let idx = sessionIndex {
      var sess = sessions[idx]
      sess.pendingApprovalId = normalizedRequestId
      sess.pendingToolName = toolName
      sess.pendingToolInput = toolInput
      sess.pendingPermissionDetail = permDetail
      sess.pendingQuestion = question
      sess.attentionReason = attention
      sess.workStatus = .permission
      sessions[idx] = sess
    }

    reconcileApprovalDispatchState(
      sessionId: sessionId,
      activeRequestId: normalizedApprovalRequestId(request.id)
    )
  }

  private func handleApprovalDecisionResult(
    sessionId: String,
    requestId: String,
    outcome: String,
    activeRequestId: String?,
    approvalVersion: UInt64
  ) {
    logger
      .info(
        "[approval] result: session=\(sessionId) request=\(requestId) outcome=\(outcome) version=\(approvalVersion)"
      )

    let obs = session(sessionId)
    obs.approvalVersion = approvalVersion

    // Clear in-flight tracking for the decided request
    clearApprovalDispatchForRequest(sessionId: sessionId, requestId: requestId)

    let normalizedDecided = normalizedApprovalRequestId(requestId)
    if let normalizedDecided {
      queuedApprovalRequests[sessionId]?.removeValue(forKey: normalizedDecided)
    }

    let normalizedActiveRequestId = normalizedApprovalRequestId(activeRequestId)

    // Only clear pending approval optimistically when the server applied the
    // decision. A stale outcome means this request did not resolve.
    if outcome == "applied" {
      // Eagerly clear the pending approval if it matches the decided request so the
      // approval card disappears immediately rather than lingering until the next
      // session state delta arrives.
      if let pending = obs.pendingApproval, normalizedApprovalRequestId(pending.id) == normalizedDecided {
        obs.pendingApproval = nil
        obs.pendingApprovalId = nil
        obs.pendingToolName = nil
        obs.pendingToolInput = nil
        obs.pendingPermissionDetail = nil
        obs.pendingQuestion = nil
        if obs.attentionReason == .awaitingPermission || obs.attentionReason == .awaitingQuestion {
          obs.attentionReason = .none
        }
        if obs.workStatus == .permission {
          obs.workStatus = .working
        }

        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
          var sess = sessions[idx]
          sess.pendingApprovalId = nil
          sess.pendingToolName = nil
          sess.pendingToolInput = nil
          sess.pendingPermissionDetail = nil
          sess.pendingQuestion = nil
          if sess.attentionReason == .awaitingPermission || sess.attentionReason == .awaitingQuestion {
            sess.attentionReason = .none
          }
          if sess.workStatus == .permission {
            sess.workStatus = .working
          }
          sessions[idx] = sess
        }
      }
    }

    if
      let normalizedActiveRequestId,
      normalizedApprovalRequestId(obs.pendingApproval?.id) != normalizedActiveRequestId,
      let promoted = queuedApprovalRequests[sessionId]?[normalizedActiveRequestId]
    {
      logger.info(
        "[approval] promoted queued request after decision: session=\(sessionId) request=\(normalizedActiveRequestId)"
      )
      queuedApprovalRequests[sessionId]?.removeValue(forKey: normalizedActiveRequestId)
      obs.pendingApproval = promoted

      let toolName = promoted.toolNameForDisplay
      let toolInput = promoted.toolInputForDisplay
      let permDetail = promoted.preview?.compact
        ?? String.shellCommandDisplay(from: promoted.command)
        ?? promoted.command
      let question = promoted.questionPrompts.first?.question ?? promoted.question
      let attention: Session.AttentionReason = promoted.type == .question ? .awaitingQuestion : .awaitingPermission

      obs.pendingApprovalId = normalizedActiveRequestId
      obs.pendingToolName = toolName
      obs.pendingToolInput = toolInput
      obs.pendingPermissionDetail = permDetail
      obs.pendingQuestion = question
      obs.attentionReason = attention
      obs.workStatus = .permission

      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        var sess = sessions[idx]
        sess.pendingApprovalId = normalizedActiveRequestId
        sess.pendingToolName = toolName
        sess.pendingToolInput = toolInput
        sess.pendingPermissionDetail = permDetail
        sess.pendingQuestion = question
        sess.attentionReason = attention
        sess.workStatus = .permission
        sessions[idx] = sess
      }
    } else if normalizedActiveRequestId == nil, obs.pendingApproval == nil {
      queuedApprovalRequests[sessionId] = nil
    }

    reconcileApprovalDispatchState(
      sessionId: sessionId,
      activeRequestId: normalizedActiveRequestId
    )

    // Refresh approval history for the history panel
    refreshApprovalHistory(sessionId: sessionId)
  }

  private func clearApprovalDispatchForRequest(sessionId: String, requestId: String) {
    let key = ApprovalDispatchKey(sessionId: sessionId, requestId: requestId)
    inFlightApprovalDispatches.remove(key)
  }

  private func shellOutputIsError(outcome: ServerShellExecutionOutcome, exitCode: Int32?) -> Bool {
    switch outcome {
      case .completed:
        exitCode != 0
      case .failed, .timedOut:
        true
      case .canceled:
        false
    }
  }

  private func handleTokensUpdated(
    _ sessionId: String,
    _ usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) {
    let obs = session(sessionId)
    obs.tokenUsage = usage
    obs.tokenUsageSnapshotKind = snapshotKind
    obs.totalTokens = Int(usage.inputTokens + usage.outputTokens)
    obs.inputTokens = Int(usage.inputTokens)
    obs.outputTokens = Int(usage.outputTokens)
    obs.cachedTokens = Int(usage.cachedTokens)
    obs.contextWindow = Int(usage.contextWindow)

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].totalTokens = Int(usage.inputTokens + usage.outputTokens)
      sessions[idx].inputTokens = Int(usage.inputTokens)
      sessions[idx].outputTokens = Int(usage.outputTokens)
      sessions[idx].cachedTokens = Int(usage.cachedTokens)
      sessions[idx].contextWindow = Int(usage.contextWindow)
      sessions[idx].tokenUsageSnapshotKind = snapshotKind
    }

    queueConversationSnapshotWrite(sessionId: sessionId, reason: "tokens-updated", mode: .metadataOnly)
  }

  private func handleContextCompacted(_ sessionId: String) {
    logger.info("Context compacted for \(sessionId)")

    let obs = session(sessionId)
    let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId })
    let sessionOutput = sessionIndex.flatMap { sessions[$0].outputTokens } ?? 0
    let sessionWindow = sessionIndex.flatMap { sessions[$0].contextWindow } ?? 0
    let outputTokens = obs.tokenUsage?.outputTokens ?? UInt64(max(sessionOutput, 0))
    let contextWindow = obs.tokenUsage?.contextWindow ?? UInt64(max(sessionWindow, 0))

    let resetUsage = ServerTokenUsage(
      inputTokens: 0,
      outputTokens: outputTokens,
      cachedTokens: 0,
      contextWindow: contextWindow
    )
    obs.tokenUsage = resetUsage
    obs.tokenUsageSnapshotKind = .compactionReset
    obs.totalTokens = Int(outputTokens)
    obs.inputTokens = 0
    obs.outputTokens = Int(outputTokens)
    obs.cachedTokens = 0
    obs.contextWindow = Int(contextWindow)

    if let idx = sessionIndex {
      sessions[idx].totalTokens = Int(outputTokens)
      sessions[idx].inputTokens = 0
      sessions[idx].outputTokens = Int(outputTokens)
      sessions[idx].cachedTokens = 0
      sessions[idx].contextWindow = Int(contextWindow)
      sessions[idx].tokenUsageSnapshotKind = .compactionReset
    }

    queueConversationSnapshotWrite(sessionId: sessionId, reason: "context-compacted", mode: .metadataOnly)
  }

  private func handleSessionCreated(_ summary: ServerSessionSummary) {
    logger.info("Session created: \(summary.id)")
    var sess = summary.toSession()
    sess.endpointId = endpointId
    sess.endpointName = connection.endpointName
    updateSessionInList(sess)

    hydrateObservable(session(summary.id), from: sess)

    if let autonomy = pendingCreationAutonomy {
      session(summary.id).autonomy = autonomy
      session(summary.id).autonomyConfiguredOnServer = true
      pendingCreationAutonomy = nil
    } else if summary.provider == .codex {
      setConfigCache(sessionId: summary.id, approvalPolicy: summary.approvalPolicy, sandboxMode: summary.sandboxMode)
      session(summary.id).autonomy = AutonomyLevel.from(
        approvalPolicy: summary.approvalPolicy,
        sandboxMode: summary.sandboxMode
      )
      session(summary.id).autonomyConfiguredOnServer = isAutonomyConfigured(
        approvalPolicy: summary.approvalPolicy,
        sandboxMode: summary.sandboxMode
      )
    } else if summary.provider == .claude, let pm = summary.permissionMode {
      permissionModes[summary.id] = pm
      session(summary.id).permissionMode = ClaudePermissionMode(rawValue: pm) ?? .default
    }

    subscribeToSession(summary.id)

    if pendingCreateInitialPrompt != nil, pendingCreatePromptTargetSessionId == nil {
      pendingCreatePromptTargetSessionId = summary.id
    }
    deliverPendingCreatePromptIfNeeded(sessionId: summary.id)

    // Navigation now handled in handleSessionSnapshot (arrives earlier with full state).
    // Fall back here only if snapshot was missed (e.g. reconnect race).
    if pendingNavigationOnCreate {
      pendingNavigationOnCreate = false
      Platform.services.playHaptic(.success)
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": SessionRef(endpointId: endpointId, sessionId: summary.id).scopedID]
      )
    }
  }

  private func handleSessionEnded(_ sessionId: String, _ reason: String) {
    logger.info("Session ended: \(sessionId) (\(reason))")

    let obs = session(sessionId)
    let endingRevision = lastRevision[sessionId]
    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].status = .ended
      sessions[idx].workStatus = .unknown
      sessions[idx].attentionReason = .none
    }
    obs.status = .ended
    obs.workStatus = .unknown
    obs.endReason = reason

    // Clear transient per-session state (keeps messages/tokens/history for viewing)
    obs.clearTransientState()

    // Clean up internal tracking
    subscribedSessions.remove(sessionId)
    autoMarkReadSessions.remove(sessionId)
    lastRevision.removeValue(forKey: sessionId)
    approvalPolicies.removeValue(forKey: sessionId)
    sandboxModes.removeValue(forKey: sessionId)
    permissionModes.removeValue(forKey: sessionId)
    queuedApprovalRequests.removeValue(forKey: sessionId)
    clearApprovalDispatchState(sessionId: sessionId)
    // Keep SessionObservable alive — user may still be viewing the conversation

    if let endingRevision {
      lastRevision[sessionId] = endingRevision
    }
    flushConversationSnapshotWrite(
      sessionId: sessionId,
      reason: "session-ended",
      mode: .replaceLoadedWindow
    )
  }

  private func deliverPendingCreatePromptIfNeeded(sessionId: String) {
    guard pendingCreatePromptTargetSessionId == sessionId,
          let prompt = pendingCreateInitialPrompt
    else { return }

    clearPendingCreateAutomation()

    let disposition = sendMessage(sessionId: sessionId, content: prompt)
    logger.info("Delivered continuation bootstrap prompt to \(sessionId): \(String(describing: disposition))")
  }

  private func clearPendingCreateAutomation() {
    pendingCreateInitialPrompt = nil
    pendingCreatePromptTargetSessionId = nil
  }

  private func handleError(_ code: String, _ message: String, _ sessionId: String?) {
    logger.error("Server error [\(code)]: \(message)")

    var handled = false

    if code == "codex_error" || code == "claude_error" {
      clearPendingCreateAutomation()
      pendingNavigationOnCreate = false
      handled = true
    }

    if code == "fork_failed" || code == "not_found" || code.hasPrefix("worktree_") {
      if let sid = sessionId {
        session(sid).forkInProgress = false
      }
      handled = true
    }

    // Conversation replay is stale or oversized — re-bootstrap over HTTP and then resume WS replay.
    if (code == "lagged" || code == "replay_oversized" || code == "snapshot_unavailable"),
       let sid = sessionId
    {
      logger.info("Re-subscribing to \(sid) after \(code, privacy: .public)")
      subscribedSessions.remove(sid)
      subscribeToSession(sid)
      handled = true
    }

    if code == "stale_approval_request", let sid = sessionId {
      clearApprovalDispatchState(sessionId: sid)
      refreshApprovalHistory(sessionId: sid)
      handled = true
    }

    if code.hasPrefix("codex_auth_") {
      codexAuthError = message
      // Only re-fetch account status for real auth errors from the server.
      // Connection failures use "codex_auth_connection" — retrying those
      // creates an infinite loop (fetch fails → error → fetch → …).
      if code == "codex_auth_error" {
        refreshCodexAccount()
      }
      handled = true
    }

    // Surface unhandled errors so they're never silent
    if !handled {
      lastServerError = (code: code, message: message)
    }
  }

  /// Clear the last server error (call after displaying it)
  func clearServerError() {
    lastServerError = nil
  }

  private func normalizedApprovalRequestId(_ requestId: String?) -> String? {
    guard let requestId else { return nil }
    let normalized = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private func isApprovalDispatchInFlight(sessionId: String, requestId: String) -> Bool {
    inFlightApprovalDispatches.contains(ApprovalDispatchKey(sessionId: sessionId, requestId: requestId))
  }

  private func markApprovalDispatchInFlight(sessionId: String, requestId: String) {
    inFlightApprovalDispatches.insert(ApprovalDispatchKey(sessionId: sessionId, requestId: requestId))
  }

  private func clearApprovalDispatchState(sessionId: String) {
    inFlightApprovalDispatches = inFlightApprovalDispatches.filter { $0.sessionId != sessionId }
  }

  private func reconcileApprovalDispatchState(sessionId: String, activeRequestId: String?) {
    let normalizedActiveRequestId = normalizedApprovalRequestId(activeRequestId)
    inFlightApprovalDispatches = inFlightApprovalDispatches.filter { key in
      guard key.sessionId == sessionId else { return true }
      guard let normalizedActiveRequestId else { return false }
      return key.requestId == normalizedActiveRequestId
    }
  }

  // MARK: - Turn Diff Handlers

  private func handleTurnDiffSnapshot(
    _ sessionId: String,
    turnId: String,
    diff: String,
    inputTokens: UInt64?,
    outputTokens: UInt64?,
    cachedTokens: UInt64?,
    contextWindow: UInt64?,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) {
    logger.debug("Turn diff snapshot for \(sessionId), turn \(turnId)")
    let obs = session(sessionId)
    let newDiff = ServerTurnDiff(
      turnId: turnId,
      diff: diff,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens,
      contextWindow: contextWindow,
      snapshotKind: snapshotKind
    )
    var turnDiffs = obs.turnDiffs
    turnDiffs.append(newDiff)
    obs.turnDiffs = normalizedTurnDiffs(turnDiffs, sessionId: sessionId, source: "delta")
    queueConversationSnapshotWrite(sessionId: sessionId, reason: "turn-diff", mode: .metadataOnly)
  }

  // MARK: - Review Comment Handlers

  private func handleReviewCommentCreated(_ sessionId: String, comment: ServerReviewComment) {
    logger.debug("Review comment created in \(sessionId): \(comment.id)")
    let obs = session(sessionId)
    if !obs.reviewComments.contains(where: { $0.id == comment.id }) {
      obs.reviewComments.append(comment)
    }
  }

  private func handleReviewCommentUpdated(_ sessionId: String, comment: ServerReviewComment) {
    logger.debug("Review comment updated in \(sessionId): \(comment.id)")
    let obs = session(sessionId)
    if let idx = obs.reviewComments.firstIndex(where: { $0.id == comment.id }) {
      obs.reviewComments[idx] = comment
    } else {
      obs.reviewComments.append(comment)
    }
  }

  private func handleReviewCommentDeleted(_ sessionId: String, commentId: String) {
    logger.debug("Review comment deleted in \(sessionId): \(commentId)")
    session(sessionId).reviewComments.removeAll { $0.id == commentId }
  }

  // MARK: - Review Comment Actions

  func createReviewComment(
    sessionId: String,
    turnId: String?,
    filePath: String,
    lineStart: UInt32,
    lineEnd: UInt32?,
    body: String,
    tag: ServerReviewCommentTag?
  ) {
    logger.info("Creating review comment in \(sessionId)")
    connection.createReviewComment(
      sessionId: sessionId,
      turnId: turnId,
      filePath: filePath,
      lineStart: lineStart,
      lineEnd: lineEnd,
      body: body,
      tag: tag
    )
  }

  func updateReviewComment(
    commentId: String,
    body: String?,
    tag: ServerReviewCommentTag?,
    status: ServerReviewCommentStatus?
  ) {
    logger.info("Updating review comment \(commentId)")
    connection.updateReviewComment(commentId: commentId, body: body, tag: tag, status: status)
  }

  func deleteReviewComment(commentId: String) {
    logger.info("Deleting review comment \(commentId)")
    connection.deleteReviewComment(commentId: commentId)
  }

  func listReviewComments(sessionId: String, turnId: String? = nil) {
    connection.listReviewComments(sessionId: sessionId, turnId: turnId)
  }

  // MARK: - Helpers

  private func applyCodexAccountStatus(_ status: ServerCodexAccountStatus) {
    codexAccountStatus = status
    if status.account != nil {
      codexAuthError = nil
    }
  }

  private func markLoginInProgress(loginId: String?) {
    let current = codexAccountStatus
    codexAccountStatus = ServerCodexAccountStatus(
      authMode: current?.authMode,
      requiresOpenaiAuth: current?.requiresOpenaiAuth ?? true,
      account: current?.account,
      loginInProgress: loginId != nil,
      activeLoginId: loginId
    )
  }

  private func openCodexAuthURL(_ authUrl: String) {
    guard let url = URL(string: authUrl) else {
      codexAuthError = "Sign-in URL was invalid."
      return
    }
    let opened = Platform.services.openURL(url)
    if !opened {
      codexAuthError = "Couldn’t open browser for ChatGPT sign-in."
    }
  }

  private func updateSessionInList(_ session: Session) {
    var stamped = session
    stamped.endpointId = stamped.endpointId ?? endpointId
    stamped.endpointName = stamped.endpointName ?? connection.endpointName
    if let idx = sessions.firstIndex(where: { $0.id == stamped.id }) {
      sessions[idx] = stamped
    } else {
      sessions.append(stamped)
    }
  }

  private func setConfigCache(sessionId: String, approvalPolicy: String?, sandboxMode: String?) {
    if let approvalPolicy {
      approvalPolicies[sessionId] = approvalPolicy
    } else {
      approvalPolicies.removeValue(forKey: sessionId)
    }

    if let sandboxMode {
      sandboxModes[sessionId] = sandboxMode
    } else {
      sandboxModes.removeValue(forKey: sessionId)
    }
  }

  private func isAutonomyConfigured(approvalPolicy: String?, sandboxMode: String?) -> Bool {
    // Codex defaults are meaningful server-side even when explicit policy/mode
    // values are omitted from summaries/deltas, so treat nil/nil as configured.
    true
  }

  private func trimInactiveSessionPayload(_ sessionId: String, reason: String) {
    guard !subscribedSessions.contains(sessionId) else { return }
    guard let obs = _sessionObservables[sessionId] else { return }

    let messageCount = obs.messages.count
    let turnDiffCount = obs.turnDiffs.count
    guard messageCount > 0 || turnDiffCount > 0 || obs.diff != nil || obs.plan != nil else { return }

    obs.clearConversationPayloadsForCaching()
    lastRevision.removeValue(forKey: sessionId)

    logger.info(
      "Trimmed inactive session payload \(sessionId, privacy: .public) reason=\(reason, privacy: .public) messages=\(messageCount, privacy: .public) turnDiffs=\(turnDiffCount, privacy: .public)"
    )
  }

  private func shouldRequestCodexConnectorData(sessionId: String) -> Bool {
    guard let session = sessions.first(where: { $0.id == sessionId }) else {
      return false
    }
    return session.isActive && session.isDirectCodex
  }

  private static func mockSessions() -> [Session] {
    let now = Date()

    let claude = Session(
      id: "mock-claude-1",
      projectPath: "/Users/demo/Developer/OrbitDock",
      projectName: "OrbitDock",
      branch: "main",
      model: "claude-sonnet-4",
      summary: "Refactor platform abstraction layer",
      status: .active,
      workStatus: .working,
      startedAt: now.addingTimeInterval(-4_200),
      lastActivityAt: now.addingTimeInterval(-20),
      lastTool: "Read",
      promptCount: 12,
      toolCount: 26,
      attentionReason: .none,
      provider: .claude,
      claudeIntegrationMode: .direct
    )

    let codex = Session(
      id: "mock-codex-1",
      projectPath: "/Users/demo/Developer/vizzly",
      projectName: "vizzly",
      branch: "feat/universal-shell",
      model: "gpt-5-codex",
      summary: "Needs approval for apply_patch",
      status: .active,
      workStatus: .permission,
      startedAt: now.addingTimeInterval(-1_800),
      lastActivityAt: now.addingTimeInterval(-90),
      lastTool: "apply_patch",
      promptCount: 5,
      toolCount: 11,
      attentionReason: .awaitingPermission,
      pendingToolName: "apply_patch",
      provider: .codex,
      codexIntegrationMode: .direct
    )

    return [claude, codex]
  }
}

// MARK: - MCP Startup State

/// Tracks per-server MCP startup status for a session
struct McpStartupState {
  /// Per-server startup status
  var serverStatuses: [String: ServerMcpStartupStatus] = [:]

  /// Servers that are ready
  var readyServers: [String] = []

  /// Servers that failed with errors
  var failedServers: [ServerMcpStartupFailure] = []

  /// Servers that were cancelled
  var cancelledServers: [String] = []

  /// Whether startup is complete
  var isComplete: Bool = false
}
