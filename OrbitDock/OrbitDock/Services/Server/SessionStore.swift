//
//  SessionStore.swift
//  OrbitDock
//
//  Session list, per-session observables, and event routing.
//  All mutations go via APIClient (HTTP); events arrive from EventStream.
//

import Foundation

private let kConversationCacheMax = 8

// MARK: - SessionStore

@Observable
@MainActor
final class SessionStore {
  let apiClient: APIClient
  let eventStream: EventStream
  let endpointId: UUID
  var endpointName: String?

  // MARK: - Observable state

  private(set) var sessions: [Session] = []
  private(set) var hasReceivedInitialSessionsList = false
  private(set) var codexModels: [ServerCodexModelOption] = []
  private(set) var claudeModels: [ServerClaudeModelOption] = []
  private(set) var codexAccountStatus: ServerCodexAccountStatus?
  private(set) var codexAuthError: String?
  private(set) var lastServerError: (code: String, message: String)?
  private(set) var worktreesByRepo: [String: [ServerWorktreeSummary]] = [:]
  private(set) var serverIsPrimary: Bool?
  private(set) var serverPrimaryClaims: [ServerClientPrimaryClaim] = []

  // MARK: - Per-session registries (not @Observable tracked)

  @ObservationIgnored private var _sessionObservables: [String: SessionObservable] = [:]
  @ObservationIgnored private var _conversationStores: [String: ConversationStore] = [:]
  @ObservationIgnored private var conversationCache: [String: CachedConversation] = [:]

  // MARK: - Private tracking

  @ObservationIgnored private var lastRevision: [String: UInt64] = [:]
  @ObservationIgnored private var approvalPolicies: [String: String] = [:]
  @ObservationIgnored private var sandboxModes: [String: String] = [:]
  @ObservationIgnored private var permissionModes: [String: String] = [:]
  @ObservationIgnored private var subscribedSessions: Set<String> = []
  @ObservationIgnored private var autoMarkReadSessions: Set<String> = []
  @ObservationIgnored private var inFlightApprovalDispatches: Set<String> = []
  @ObservationIgnored private var eventProcessingTask: Task<Void, Never>?

  init(apiClient: APIClient, eventStream: EventStream, endpointId: UUID, endpointName: String? = nil) {
    self.apiClient = apiClient
    self.eventStream = eventStream
    self.endpointId = endpointId
    self.endpointName = endpointName
  }

  /// Convenience initializer for SwiftUI previews
  convenience init() {
    let url = URL(string: "http://127.0.0.1:3000")!
    self.init(
      apiClient: APIClient(serverURL: url, authToken: nil),
      eventStream: EventStream(authToken: nil),
      endpointId: UUID()
    )
  }

  // MARK: - Per-session accessors

  func session(_ id: String) -> SessionObservable {
    if let existing = _sessionObservables[id] { return existing }
    let obs = SessionObservable(id: id)
    _sessionObservables[id] = obs
    return obs
  }

  func conversation(_ id: String) -> ConversationStore {
    if let existing = _conversationStores[id] { return existing }
    let store = ConversationStore(sessionId: id, apiClient: apiClient)
    _conversationStores[id] = store
    return store
  }

  // MARK: - Event processing

  func startProcessingEvents() {
    eventProcessingTask?.cancel()
    netLog(.info, cat: .store, "Started event processing", data: ["endpointId": self.endpointId.uuidString])
    eventProcessingTask = Task { [weak self] in
      guard let self else { return }
      for await event in eventStream.events {
        guard !Task.isCancelled else { break }
        self.routeEvent(event)
      }
    }
  }

  func stopProcessingEvents() {
    eventProcessingTask?.cancel()
    eventProcessingTask = nil
    netLog(.info, cat: .store, "Stopped event processing", data: ["endpointId": self.endpointId.uuidString])
  }

  // MARK: - Session subscription

  func subscribeToSession(_ sessionId: String, forceRefresh: Bool = false) {
    subscribedSessions.insert(sessionId)

    let obs = session(sessionId)
    let conv = conversation(sessionId)

    if !forceRefresh, conv.hasReceivedInitialData {
      // Path 1: Retained snapshot — already have messages, just re-subscribe WS
      netLog(.info, cat: .store, "Subscribe: Path 1 — retained snapshot, re-subscribing WS", sid: sessionId)
      eventStream.subscribeSession(
        sessionId,
        sinceRevision: nil,
        includeSnapshot: true
      )
    } else if !forceRefresh, let cached = conversationCache.removeValue(forKey: sessionId) {
      // Path 2: Cached messages — restore for instant display, subscribe for delta
      netLog(.info, cat: .store, "Subscribe: Path 2 — restoring from cache, WS + HTTP reconcile", sid: sessionId)
      conv.restoreFromCache(cached)
      syncConversationToObservable(conv, obs: obs)
      eventStream.subscribeSession(
        sessionId,
        sinceRevision: lastRevision[sessionId],
        includeSnapshot: false
      )
      // Background reconcile via HTTP bootstrap
      Task {
        _ = await conv.bootstrap()
        syncConversationToObservable(conv, obs: obs)
      }
    } else {
      // Path 3: Bootstrap — fresh HTTP load, then subscribe
      netLog(.info, cat: .store, "Subscribe: Path 3 — fresh HTTP bootstrap", sid: sessionId)
      Task {
        let revision = await conv.bootstrap()
        syncConversationToObservable(conv, obs: obs)
        eventStream.subscribeSession(
          sessionId,
          sinceRevision: revision,
          includeSnapshot: false
        )
      }
    }

    // Fetch approval history
    Task {
      do {
        let response = try await apiClient.listApprovals(sessionId: sessionId, limit: 200)
        obs.approvalHistory = response.approvals
      } catch {
        netLog(.error, cat: .store, "Load approvals failed", sid: sessionId, data: ["error": error.localizedDescription])
      }
    }
  }

  func unsubscribeFromSession(_ sessionId: String) {
    netLog(.info, cat: .store, "Unsubscribe", sid: sessionId)
    subscribedSessions.remove(sessionId)
    autoMarkReadSessions.remove(sessionId)
    eventStream.unsubscribeSession(sessionId)
    cacheConversationBeforeTrim(sessionId: sessionId)
    trimInactiveSessionPayload(sessionId)
  }

  func isSessionSubscribed(_ sessionId: String) -> Bool {
    subscribedSessions.contains(sessionId)
  }

  // MARK: - Session actions (all HTTP via APIClient)

  func sendMessage(
    sessionId: String, content: String, model: String? = nil,
    effort: String? = nil, skills: [ServerSkillInput] = [],
    images: [ServerImageInput] = [], mentions: [ServerMentionInput] = []
  ) async throws {
    netLog(.info, cat: .store, "Send message", sid: sessionId)
    var request = APIClient.SendMessageRequest(content: content)
    request.model = model
    request.effort = effort
    request.skills = skills
    request.images = images
    request.mentions = mentions
    try await apiClient.sendMessage(sessionId, request: request)
  }

  func steerTurn(
    sessionId: String, content: String,
    images: [ServerImageInput] = [], mentions: [ServerMentionInput] = []
  ) async throws {
    var request = APIClient.SteerTurnRequest(content: content)
    request.images = images
    request.mentions = mentions
    try await apiClient.steerTurn(sessionId, request: request)
  }

  func approveTool(
    sessionId: String, requestId: String, decision: String,
    message: String? = nil, interrupt: Bool? = nil
  ) async throws {
    netLog(.info, cat: .store, "Approve tool", sid: sessionId, data: ["requestId": requestId, "decision": decision])
    var request = APIClient.ApproveToolRequest(requestId: requestId, decision: decision)
    request.message = message
    request.interrupt = interrupt
    _ = try await apiClient.approveTool(sessionId, request: request)
  }

  func answerQuestion(
    sessionId: String, requestId: String, answer: String,
    questionId: String? = nil, answers: [String: [String]] = [:]
  ) async throws {
    netLog(.info, cat: .store, "Answer question", sid: sessionId, data: ["requestId": requestId])
    var request = APIClient.AnswerQuestionRequest(requestId: requestId, answer: answer)
    request.questionId = questionId
    request.answers = answers
    _ = try await apiClient.answerQuestion(sessionId, request: request)
  }

  func createSession(_ request: APIClient.CreateSessionRequest) async throws -> APIClient.CreateSessionResponse {
    netLog(.info, cat: .store, "Create session", data: ["provider": request.provider, "cwd": request.cwd])
    return try await apiClient.createSession(request)
  }

  func resumeSession(_ sessionId: String) async throws {
    _ = try await apiClient.resumeSession(sessionId)
  }

  func endSession(_ sessionId: String) async throws {
    netLog(.info, cat: .store, "End session", sid: sessionId)
    try await apiClient.endSession(sessionId)
  }

  func interruptSession(_ sessionId: String) async throws {
    netLog(.info, cat: .store, "Interrupt session", sid: sessionId)
    try await apiClient.interruptSession(sessionId)
  }

  func takeoverSession(_ sessionId: String) async throws {
    _ = try await apiClient.takeoverSession(sessionId, request: APIClient.TakeoverRequest())
  }

  func renameSession(_ sessionId: String, name: String?) async throws {
    try await apiClient.renameSession(sessionId, name: name)
  }

  func updateSessionConfig(
    _ sessionId: String,
    approvalPolicy: String? = nil, sandboxMode: String? = nil,
    permissionMode: String? = nil
  ) async throws {
    let config = APIClient.UpdateSessionConfigRequest(
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      permissionMode: permissionMode
    )
    try await apiClient.updateSessionConfig(sessionId, config: config)
  }

  func forkSession(sessionId: String, nthUserMessage: UInt32?) async throws {
    session(sessionId).forkInProgress = true
    do {
      var request = APIClient.ForkRequest()
      request.nthUserMessage = nthUserMessage
      _ = try await apiClient.forkSession(sessionId, request: request)
    } catch {
      session(sessionId).forkInProgress = false
      throw error
    }
  }

  func forkSessionToWorktree(
    sessionId: String, branchName: String, baseBranch: String?,
    nthUserMessage: UInt32?
  ) async throws {
    session(sessionId).forkInProgress = true
    do {
      var request = APIClient.ForkToWorktreeRequest(branchName: branchName)
      request.baseBranch = baseBranch
      request.nthUserMessage = nthUserMessage
      _ = try await apiClient.forkSessionToWorktree(sessionId, request: request)
    } catch {
      session(sessionId).forkInProgress = false
      throw error
    }
  }

  func forkSessionToExistingWorktree(
    sessionId: String, worktreeId: String, nthUserMessage: UInt32?
  ) async throws {
    session(sessionId).forkInProgress = true
    do {
      let request = APIClient.ForkToExistingWorktreeRequest(
        worktreeId: worktreeId, nthUserMessage: nthUserMessage
      )
      _ = try await apiClient.forkSessionToExistingWorktree(sessionId, request: request)
    } catch {
      session(sessionId).forkInProgress = false
      throw error
    }
  }

  func compactContext(_ sessionId: String) async throws {
    try await apiClient.compactContext(sessionId)
  }

  func undoLastTurn(_ sessionId: String) async throws {
    session(sessionId).undoInProgress = true
    do {
      try await apiClient.undoLastTurn(sessionId)
    } catch {
      session(sessionId).undoInProgress = false
      throw error
    }
  }

  func rollbackTurns(_ sessionId: String, numTurns: UInt32) async throws {
    try await apiClient.rollbackTurns(sessionId, numTurns: numTurns)
  }

  func rewindFiles(_ sessionId: String, userMessageId: String) async throws {
    try await apiClient.rewindFiles(sessionId, userMessageId: userMessageId)
  }

  func stopTask(_ sessionId: String, taskId: String) async throws {
    try await apiClient.stopTask(sessionId, taskId: taskId)
  }

  func executeShell(_ sessionId: String, command: String) async throws {
    try await apiClient.executeShell(sessionId: sessionId, command: command)
  }

  func cancelShell(_ sessionId: String, requestId: String) async throws {
    try await apiClient.cancelShell(sessionId: sessionId, requestId: requestId)
  }

  func loadOlderMessages(sessionId: String, limit: Int = 50) {
    conversation(sessionId).loadOlderMessages(limit: limit)
  }

  func setSessionAutoMarkRead(_ sessionId: String, enabled: Bool) {
    if enabled {
      autoMarkReadSessions.insert(sessionId)
    } else {
      autoMarkReadSessions.remove(sessionId)
    }
  }

  func markSessionAsRead(_ sessionId: String) {
    Task {
      do {
        let newCount = try await apiClient.markSessionRead(sessionId)
        session(sessionId).unreadCount = newCount
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
          sessions[idx].unreadCount = newCount
        }
        notifySessionsChanged()
      } catch {
        netLog(.error, cat: .store, "Mark read failed", sid: sessionId, data: ["error": error.localizedDescription])
      }
    }
  }

  func uploadImageAttachment(
    sessionId: String, data: Data, mimeType: String,
    displayName: String, pixelWidth: Int, pixelHeight: Int
  ) async throws -> ServerImageInput {
    try await apiClient.uploadImageAttachment(
      sessionId: sessionId, data: data, mimeType: mimeType,
      displayName: displayName, pixelWidth: pixelWidth, pixelHeight: pixelHeight
    )
  }

  func loadPermissionRules(sessionId: String, forceRefresh: Bool = false) async throws -> ServerSessionPermissionRules {
    let obs = session(sessionId)
    if !forceRefresh, let cached = obs.permissionRules {
      return cached
    }
    obs.permissionRulesLoading = true
    defer { obs.permissionRulesLoading = false }
    let response = try await apiClient.fetchPermissionRules(sessionId)
    obs.permissionRules = response.rules
    return response.rules
  }

  func addPermissionRule(
    sessionId: String, pattern: String, behavior: String,
    scope: String
  ) async throws {
    try await apiClient.addPermissionRule(
      sessionId: sessionId, pattern: pattern,
      behavior: behavior, scope: scope
    )
    // Refresh rules after mutation
    _ = try await loadPermissionRules(sessionId: sessionId, forceRefresh: true)
  }

  func removePermissionRule(
    sessionId: String, pattern: String, behavior: String,
    scope: String
  ) async throws {
    try await apiClient.removePermissionRule(
      sessionId: sessionId, pattern: pattern,
      behavior: behavior, scope: scope
    )
    _ = try await loadPermissionRules(sessionId: sessionId, forceRefresh: true)
  }

  func updateClaudePermissionMode(_ sessionId: String, mode: ClaudePermissionMode) async throws {
    try await updateSessionConfig(sessionId, permissionMode: mode.rawValue)
    session(sessionId).permissionMode = mode
  }

  func getSubagentTools(sessionId: String, subagentId: String) {
    Task {
      let tools = try await apiClient.getSubagentTools(sessionId: sessionId, subagentId: subagentId)
      session(sessionId).subagentTools[subagentId] = tools
    }
  }

  /// Sync accessor: returns the pending approval's request ID if any
  func nextPendingApprovalRequestId(sessionId: String) -> String? {
    session(sessionId).pendingApproval?.id
  }

  /// Sync accessor: returns the pending approval's type if it matches the request ID
  func pendingApprovalType(sessionId: String, requestId: String) -> ServerApprovalType? {
    guard let approval = session(sessionId).pendingApproval,
          approval.id == requestId else { return nil }
    return approval.type
  }

  func listSkills(sessionId: String) async throws {
    let response = try await apiClient.listSkills(sessionId: sessionId)
    let obs = session(sessionId)
    let allSkills = response.skills.flatMap(\.skills)
    obs.skills = allSkills
  }

  func listMcpTools(sessionId: String) async throws {
    let response = try await apiClient.listMcpTools(sessionId: sessionId)
    let obs = session(sessionId)
    obs.mcpTools = response.tools
    obs.mcpResources = response.resources
    obs.mcpAuthStatuses = response.authStatuses
  }

  func refreshMcpServers(_ sessionId: String) async throws {
    try await apiClient.refreshMcpServers(sessionId: sessionId)
  }

  func listReviewComments(sessionId: String, turnId: String?) async throws {
    let response = try await apiClient.listReviewComments(sessionId: sessionId, turnId: turnId)
    session(sessionId).reviewComments = response.comments
  }

  func worktrees(for repoRoot: String) -> [ServerWorktreeSummary] {
    worktreesByRepo[repoRoot] ?? []
  }

  func refreshWorktreesForActiveSessions() {
    let roots = Set(sessions.filter(\.isActive).map(\.groupingPath))
    for root in roots {
      Task {
        do {
          let wts = try await apiClient.listWorktrees(repoRoot: root)
          worktreesByRepo[root] = wts
        } catch {
          netLog(.error, cat: .store, "List worktrees failed", data: ["repoRoot": root, "error": error.localizedDescription])
        }
      }
    }
  }

  func refreshSessionsList() {
    eventStream.subscribeList()
  }

  func clearServerError() {
    lastServerError = nil
  }

  func setServerRole(isPrimary: Bool) {
    Task {
      do {
        _ = try await apiClient.setServerRole(isPrimary: isPrimary)
      } catch {
        netLog(.error, cat: .store, "Set server role failed", data: ["error": error.localizedDescription])
      }
    }
  }

  func setClientPrimaryClaim(clientId: String, deviceName: String, isPrimary: Bool) {
    Task {
      do {
        try await apiClient.setClientPrimaryClaim(
          clientId: clientId, deviceName: deviceName, isPrimary: isPrimary
        )
      } catch {
        netLog(.error, cat: .store, "Set client primary claim failed", data: ["error": error.localizedDescription])
      }
    }
  }

  /// Whether this endpoint has a remote (non-localhost) server.
  var isRemoteConnection: Bool {
    eventStream.isRemote
  }

  /// Shared project file index for @ mention completions.
  let projectFileIndex = ProjectFileIndex()

  func refreshCodexModels() {
    Task { codexModels = (try? await apiClient.listCodexModels()) ?? codexModels }
  }

  func refreshClaudeModels() {
    Task { claudeModels = (try? await apiClient.listClaudeModels()) ?? claudeModels }
  }

  func handleMemoryPressure() {
    conversationCache.removeAll()
    for (id, _) in _conversationStores where !subscribedSessions.contains(id) {
      _conversationStores[id]?.clear()
      _conversationStores.removeValue(forKey: id)
    }
  }

  // MARK: - Event routing

  private func routeEvent(_ event: ServerEvent) {
    netLog(.debug, cat: .store, "Event: \(self.eventSummary(event))")
    switch event {
    // Session list
    case .sessionsList(let summaries):
      handleSessionsList(summaries)
    case .sessionCreated(let summary):
      handleSessionCreated(summary)
    case .sessionEnded(let sessionId, let reason):
      handleSessionEnded(sessionId, reason)

    // Session state
    case .sessionSnapshot(let state):
      handleSessionSnapshot(state)
    case .sessionDelta(let sessionId, let changes):
      handleSessionDelta(sessionId, changes)

    // Messages
    case .messageAppended(let sessionId, let message):
      handleMessageAppended(sessionId, message)
    case .messageUpdated(let sessionId, let messageId, let changes):
      handleMessageUpdated(sessionId, messageId, changes)

    // Approvals
    case .approvalRequested(let sessionId, let request, let version):
      handleApprovalRequested(sessionId, request, version)
    case .approvalDecisionResult(let sessionId, let requestId, let outcome, let activeId, let version):
      handleApprovalDecisionResult(sessionId, requestId, outcome, activeId, version)
    case .approvalsList(let sessionId, let approvals):
      handleApprovalsList(sessionId, approvals)
    case .approvalDeleted(let approvalId):
      handleApprovalDeleted(approvalId)

    // Tokens
    case .tokensUpdated(let sessionId, let usage, let kind):
      let obs = session(sessionId)
      obs.tokenUsage = usage
      obs.tokenUsageSnapshotKind = kind
      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        sessions[idx].inputTokens = Int(usage.inputTokens)
        sessions[idx].outputTokens = Int(usage.outputTokens)
        sessions[idx].cachedTokens = Int(usage.cachedTokens)
        sessions[idx].contextWindow = Int(usage.contextWindow)
        sessions[idx].totalTokens = Int(usage.inputTokens + usage.outputTokens)
        sessions[idx].tokenUsageSnapshotKind = kind
      }

    // Models / Codex account
    case .modelsList(let models):
      codexModels = models
    case .claudeModelsList(let models):
      claudeModels = models
    case .codexAccountStatus(let status):
      codexAccountStatus = status
    case .codexAccountUpdated(let status):
      codexAccountStatus = status
    case .codexLoginChatgptStarted, .codexLoginChatgptCompleted, .codexLoginChatgptCanceled:
      break // Handled by UI directly if needed

    // Skills
    case .skillsList(let sessionId, let skills, _):
      let obs = session(sessionId)
      obs.skills = skills.flatMap(\.skills)
    case .remoteSkillsList, .remoteSkillDownloaded, .skillsUpdateAvailable:
      break // Handled by skill UI if needed

    // MCP
    case .mcpToolsList(let sessionId, let tools, let resources, _, let authStatuses):
      let obs = session(sessionId)
      obs.mcpTools = tools
      obs.mcpResources = resources
      obs.mcpAuthStatuses = authStatuses
    case .mcpStartupUpdate(let sessionId, let server, let status):
      let obs = session(sessionId)
      if obs.mcpStartupState == nil {
        obs.mcpStartupState = McpStartupState()
      }
      obs.mcpStartupState?.serverStatuses[server] = status
    case .mcpStartupComplete(let sessionId, let ready, let failed, let cancelled):
      let obs = session(sessionId)
      if obs.mcpStartupState == nil {
        obs.mcpStartupState = McpStartupState()
      }
      obs.mcpStartupState?.isComplete = true
      obs.mcpStartupState?.readyServers = ready
      obs.mcpStartupState?.failedServers = failed
      obs.mcpStartupState?.cancelledServers = cancelled

    // Claude capabilities
    case .claudeCapabilities(let sessionId, let slashCommands, let skills, let tools, let models):
      let obs = session(sessionId)
      obs.slashCommands = Set(slashCommands)
      obs.claudeSkillNames = skills
      obs.claudeToolNames = tools
      claudeModels = models

    // Context / undo / fork
    case .contextCompacted:
      break
    case .undoStarted(let sessionId, let message):
      let obs = session(sessionId)
      obs.undoInProgress = true
      if let message {
        netLog(.info, cat: .store, "Undo started", sid: sessionId, data: ["message": message])
      }
    case .undoCompleted(let sessionId, let success, _):
      let obs = session(sessionId)
      obs.undoInProgress = false
      if success {
        // Re-bootstrap conversation to get updated messages
        let conv = conversation(sessionId)
        Task {
          _ = await conv.bootstrap()
          syncConversationToObservable(conv, obs: obs)
        }
      }
    case .threadRolledBack(let sessionId, _):
      let conv = conversation(sessionId)
      let obs = session(sessionId)
      Task {
        _ = await conv.bootstrap()
        syncConversationToObservable(conv, obs: obs)
      }
    case .sessionForked(let sourceSessionId, let newSessionId, _):
      let obs = session(sourceSessionId)
      obs.forkInProgress = false
      let newObs = session(newSessionId)
      newObs.forkedFrom = sourceSessionId
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": newSessionId, "endpointId": endpointId]
      )

    // Turn diffs
    case .turnDiffSnapshot(let sessionId, let turnId, let diff, let input, let output, let cached, let window, let kind):
      let obs = session(sessionId)
      let turnDiff = ServerTurnDiff(
        turnId: turnId, diff: diff,
        inputTokens: input, outputTokens: output,
        cachedTokens: cached, contextWindow: window
      )
      if let idx = obs.turnDiffs.firstIndex(where: { $0.turnId == turnId }) {
        obs.turnDiffs[idx] = turnDiff
      } else {
        obs.turnDiffs.append(turnDiff)
      }
      obs.tokenUsageSnapshotKind = kind
      if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
        sessions[idx].tokenUsageSnapshotKind = kind
        if let input { sessions[idx].inputTokens = Int(input) }
        if let output { sessions[idx].outputTokens = Int(output) }
        if let cached { sessions[idx].cachedTokens = Int(cached) }
        if let window { sessions[idx].contextWindow = Int(window) }
      }

    // Review comments
    case .reviewCommentCreated(let sessionId, _, let comment):
      let obs = session(sessionId)
      obs.reviewComments.append(comment)
    case .reviewCommentUpdated(let sessionId, _, let comment):
      let obs = session(sessionId)
      if let idx = obs.reviewComments.firstIndex(where: { $0.id == comment.id }) {
        obs.reviewComments[idx] = comment
      }
    case .reviewCommentDeleted(let sessionId, _, let commentId):
      let obs = session(sessionId)
      obs.reviewComments.removeAll { $0.id == commentId }
    case .reviewCommentsList(let sessionId, _, let comments):
      session(sessionId).reviewComments = comments

    // Subagent
    case .subagentToolsList(let sessionId, let subagentId, let tools):
      session(sessionId).subagentTools[subagentId] = tools

    // Shell
    case .shellStarted:
      break
    case .shellOutput(let sessionId, _, _, _, _, _, _):
      // Shell output is routed to the session's pending shell context
      // The message content is handled via messageUpdated events
      _ = session(sessionId)

    // Worktrees
    case .worktreesList(_, let repoRoot, _, let worktrees):
      if let root = repoRoot {
        worktreesByRepo[root] = worktrees
      }
    case .worktreeCreated(_, _, _, let worktree):
      let root = worktree.repoRoot
      if worktreesByRepo[root] != nil {
        worktreesByRepo[root]?.append(worktree)
      } else {
        worktreesByRepo[root] = [worktree]
      }
    case .worktreeRemoved(_, let repoRoot, _, let worktreeId):
      worktreesByRepo[repoRoot]?.removeAll { $0.id == worktreeId }
    case .worktreeStatusChanged(let worktreeId, let status, let repoRoot):
      if var wts = worktreesByRepo[repoRoot],
         let idx = wts.firstIndex(where: { $0.id == worktreeId }) {
        wts[idx].status = status
        worktreesByRepo[repoRoot] = wts
      }
    case .worktreeError:
      break

    // Rate limit
    case .rateLimitEvent(let sessionId, let info):
      session(sessionId).rateLimitInfo = info

    // Misc
    case .promptSuggestion(let sessionId, let suggestion):
      session(sessionId).promptSuggestions.append(suggestion)
    case .filesPersisted(let sessionId, _):
      session(sessionId).lastFilesPersistedAt = Date()
    case .serverInfo(let isPrimary, let claims):
      serverIsPrimary = isPrimary
      serverPrimaryClaims = claims

    // Permission rules
    case .permissionRules(let sessionId, let rules):
      session(sessionId).permissionRules = rules

    // Error
    case .error(let code, let message, let sessionId):
      handleError(code, message, sessionId)

    // Connection lifecycle
    case .connectionStatusChanged(let status):
      handleConnectionStatusChanged(status)

    // Revision tracking
    case .revision(let sessionId, let revision):
      lastRevision[sessionId] = revision
    }
  }

  private func eventSummary(_ event: ServerEvent) -> String {
    switch event {
    case .sessionsList(let sessions): "sessionsList(\(sessions.count))"
    case .sessionCreated(let s): "sessionCreated(\(s.id))"
    case .sessionEnded(let sid, _): "sessionEnded(\(sid))"
    case .sessionSnapshot(let s): "sessionSnapshot(\(s.id))"
    case .sessionDelta(let sid, _): "sessionDelta(\(sid))"
    case .messageAppended(let sid, let msg): "messageAppended(\(sid), \(msg.id))"
    case .messageUpdated(let sid, let mid, _): "messageUpdated(\(sid), \(mid))"
    case .approvalRequested(let sid, _, _): "approvalRequested(\(sid))"
    case .approvalDecisionResult(let sid, let rid, let outcome, _, _): "approvalResult(\(sid), \(rid), \(outcome))"
    case .connectionStatusChanged(let status): "connectionStatus(\(status))"
    case .revision(let sid, let rev): "revision(\(sid), \(rev))"
    case .error(let code, let msg, let sid): "error(\(code), \(msg), \(sid ?? "nil"))"
    default: String(describing: event).prefix(80).description
    }
  }

  // MARK: - Event handlers

  private func handleSessionsList(_ summaries: [ServerSessionSummary]) {
    netLog(.info, cat: .store, "Received sessions list", data: ["count": summaries.count])
    hasReceivedInitialSessionsList = true

    let currentById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

    sessions = summaries.map { summary in
      if subscribedSessions.contains(summary.id), let existing = currentById[summary.id] {
        return existing
      }
      var s = summary.toSession()
      s.endpointId = endpointId
      s.endpointName = endpointName
      return s
    }

    // Hydrate observables for non-subscribed sessions
    for sess in sessions where !subscribedSessions.contains(sess.id) {
      hydrateObservable(session(sess.id), from: sess)
    }

    // Clean up stale observables
    let liveIds = Set(summaries.map(\.id))
    let staleIds = _sessionObservables.keys.filter { !liveIds.contains($0) }
    for id in staleIds {
      _sessionObservables.removeValue(forKey: id)
      _conversationStores[id]?.clear()
      _conversationStores.removeValue(forKey: id)
    }

    NotificationCenter.default.post(name: .serverSessionsDidChange, object: nil)
  }

  private func handleSessionCreated(_ summary: ServerSessionSummary) {
    var sess = summary.toSession()
    sess.endpointId = endpointId
    sess.endpointName = endpointName
    updateSessionInList(sess)
    hydrateObservable(session(summary.id), from: sess)
  }

  private func handleSessionEnded(_ sessionId: String, _ reason: String) {
    let obs = session(sessionId)
    obs.status = .ended
    obs.endReason = reason
    obs.endedAt = Date()
    obs.pendingApproval = nil
    obs.clearTransientState()

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].status = .ended
      sessions[idx].endedAt = Date()
    }
    notifySessionsChanged()
  }

  private func handleSessionSnapshot(_ state: ServerSessionState) {
    netLog(.info, cat: .store, "Received snapshot", sid: state.id, data: ["messageCount": state.messages.count])

    if let rev = state.revision {
      lastRevision[state.id] = rev
    }

    subscribedSessions.insert(state.id)

    var sess = state.toSession()
    sess.customName = state.customName
    updateSessionInList(sess)

    let obs = session(state.id)
    hydrateObservable(obs, from: sess)

    // Route messages through ConversationStore
    let conv = conversation(state.id)
    conv.handleSnapshot(state)
    syncConversationToObservable(conv, obs: obs)

    // Approval state
    if let approval = state.pendingApproval {
      obs.pendingApproval = approval
    } else {
      obs.pendingApproval = nil
    }
    if let version = state.approvalVersion {
      obs.approvalVersion = version
    }

    obs.tokenUsage = state.tokenUsage
    obs.tokenUsageSnapshotKind = state.tokenUsageSnapshotKind

    if state.provider == .codex || state.claudeIntegrationMode == .direct {
      setConfigCache(
        sessionId: state.id,
        approvalPolicy: state.approvalPolicy,
        sandboxMode: state.sandboxMode
      )
      obs.autonomy = AutonomyLevel.from(
        approvalPolicy: approvalPolicies[state.id],
        sandboxMode: sandboxModes[state.id]
      )
      obs.autonomyConfiguredOnServer = true
    }
    if let pm = state.permissionMode {
      permissionModes[state.id] = pm
      obs.permissionMode = ClaudePermissionMode(rawValue: pm) ?? .default
    }

    obs.hasReceivedSnapshot = true
  }

  private func handleSessionDelta(_ sessionId: String, _ changes: ServerStateChanges) {
    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
    var sess = sessions[idx]
    let obs = session(sessionId)

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
      if mapped == .working {
        obs.promptSuggestions.removeAll()
        obs.rateLimitInfo = nil
      }
    }

    // Approval delta
    if let approvalOuter = changes.pendingApproval {
      let incomingVersion = changes.approvalVersion ?? 0
      let isStale = incomingVersion > 0 && incomingVersion < obs.approvalVersion
      if !isStale {
        if incomingVersion > 0 { obs.approvalVersion = incomingVersion }
        if let approval = approvalOuter {
          obs.pendingApproval = approval
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

    // Token usage
    if let usage = changes.tokenUsage {
      obs.tokenUsage = usage
      let total = Int(usage.inputTokens + usage.outputTokens)
      sess.totalTokens = total
      sess.inputTokens = Int(usage.inputTokens)
      sess.outputTokens = Int(usage.outputTokens)
      sess.cachedTokens = Int(usage.cachedTokens)
      sess.contextWindow = Int(usage.contextWindow)
      obs.totalTokens = total
      obs.inputTokens = Int(usage.inputTokens)
      obs.outputTokens = Int(usage.outputTokens)
      obs.cachedTokens = Int(usage.cachedTokens)
      obs.contextWindow = Int(usage.contextWindow)
    }
    if let snapshotKind = changes.tokenUsageSnapshotKind {
      obs.tokenUsageSnapshotKind = snapshotKind
      sess.tokenUsageSnapshotKind = snapshotKind
    }

    // Diff / plan
    if let diffOuter = changes.currentDiff {
      obs.diff = diffOuter
      sess.currentDiff = diffOuter
    }
    if let planOuter = changes.currentPlan {
      obs.plan = planOuter
    }

    // Metadata
    if let val = changes.customName { sess.customName = val; obs.customName = val }
    if let val = changes.summary { sess.summary = val; obs.summary = val }
    if let val = changes.firstPrompt { sess.firstPrompt = val; obs.firstPrompt = val }
    if let val = changes.lastMessage { sess.lastMessage = val; obs.lastMessage = val }
    if let modeOuter = changes.codexIntegrationMode {
      let val = modeOuter.flatMap { $0.toSessionMode() }
      sess.codexIntegrationMode = val; obs.codexIntegrationMode = val
    }
    if let modeOuter = changes.claudeIntegrationMode {
      let val = modeOuter.flatMap { $0.toSessionMode() }
      sess.claudeIntegrationMode = val; obs.claudeIntegrationMode = val
    }

    // Config cache
    if let approvalOuter = changes.approvalPolicy {
      setConfigCache(sessionId: sessionId, approvalPolicy: approvalOuter, sandboxMode: sandboxModes[sessionId])
    }
    if let sandboxOuter = changes.sandboxMode {
      setConfigCache(sessionId: sessionId, approvalPolicy: approvalPolicies[sessionId], sandboxMode: sandboxOuter)
    }
    if changes.approvalPolicy != nil || changes.sandboxMode != nil {
      obs.autonomy = AutonomyLevel.from(
        approvalPolicy: approvalPolicies[sessionId],
        sandboxMode: sandboxModes[sessionId]
      )
      obs.autonomyConfiguredOnServer = true
    }

    // Turn tracking
    if let turnIdOuter = changes.currentTurnId {
      obs.currentTurnId = turnIdOuter
    }
    if let count = changes.turnCount { obs.turnCount = count }

    // Git / CWD
    if let val = changes.gitBranch { sess.branch = val; obs.branch = val }
    if let val = changes.gitSha { sess.gitSha = val; obs.gitSha = val }
    if let val = changes.currentCwd { sess.currentCwd = val; obs.currentCwd = val }
    if let val = changes.model { sess.model = val; obs.model = val }
    if let val = changes.effort { sess.effort = val; obs.effort = val }

    // Permission mode
    if let pmOuter = changes.permissionMode {
      if let pm = pmOuter {
        permissionModes[sessionId] = pm
      } else {
        permissionModes.removeValue(forKey: sessionId)
      }
      obs.permissionMode = ClaudePermissionMode(rawValue: permissionModes[sessionId] ?? "default") ?? .default
    }

    // Activity
    if let lastActivity = changes.lastActivityAt {
      let stripped = lastActivity.hasSuffix("Z") ? String(lastActivity.dropLast()) : lastActivity
      if let secs = TimeInterval(stripped) {
        let date = Date(timeIntervalSince1970: secs)
        sess.lastActivityAt = date
        obs.lastActivityAt = date
      }
    }

    if let val = changes.repositoryRoot { sess.repositoryRoot = val; obs.repositoryRoot = val }
    if let isWt = changes.isWorktree { sess.isWorktree = isWt; obs.isWorktree = isWt }
    if let count = changes.unreadCount { sess.unreadCount = count; obs.unreadCount = count }

    // Stale approval scrub
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
    }

    sessions[idx] = sess
    notifySessionsChanged()
  }

  private func handleMessageAppended(_ sessionId: String, _ message: ServerMessage) {
    netLog(.debug, cat: .store, "Message appended", sid: sessionId, data: ["messageId": message.id])
    let conv = conversation(sessionId)
    conv.handleMessageAppended(message)
    let obs = session(sessionId)
    syncConversationToObservable(conv, obs: obs)

    // Auto mark-read
    if autoMarkReadSessions.contains(sessionId) {
      markSessionAsRead(sessionId)
    }
  }

  private func handleMessageUpdated(_ sessionId: String, _ messageId: String, _ changes: ServerMessageChanges) {
    let conv = conversation(sessionId)
    conv.handleMessageUpdated(messageId: messageId, changes: changes)
    let obs = session(sessionId)
    syncConversationToObservable(conv, obs: obs)
  }

  private func handleApprovalRequested(_ sessionId: String, _ request: ServerApprovalRequest, _ version: UInt64?) {
    let obs = session(sessionId)
    if let version, version > 0 {
      if version < obs.approvalVersion { return } // stale
      obs.approvalVersion = version
    }
    obs.pendingApproval = request
    obs.pendingApprovalId = request.id
    obs.pendingToolName = request.toolNameForDisplay
    obs.pendingToolInput = request.toolInputForDisplay
    obs.pendingPermissionDetail = request.preview?.compact
      ?? String.shellCommandDisplay(from: request.command)
      ?? request.command
    obs.pendingQuestion = request.questionPrompts.first?.question ?? request.question

    let attention: Session.AttentionReason = request.type == .question ? .awaitingQuestion : .awaitingPermission
    obs.attentionReason = attention
    obs.workStatus = .permission

    if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
      sessions[idx].pendingApprovalId = request.id
      sessions[idx].attentionReason = attention
      sessions[idx].workStatus = .permission
    }
  }

  private func handleApprovalDecisionResult(
    _ sessionId: String, _ requestId: String, _ outcome: String,
    _ activeRequestId: String?, _ version: UInt64
  ) {
    let obs = session(sessionId)
    obs.approvalVersion = version

    // If the decided request matches current pending, clear it
    if obs.pendingApproval?.id == requestId || obs.pendingApprovalId == requestId {
      if activeRequestId == nil {
        obs.pendingApproval = nil
        obs.pendingApprovalId = nil
        obs.pendingToolName = nil
        obs.pendingToolInput = nil
        obs.pendingPermissionDetail = nil
        obs.pendingQuestion = nil
      }
    }

    inFlightApprovalDispatches.remove(requestId)
  }

  private func handleApprovalsList(_ sessionId: String?, _ approvals: [ServerApprovalHistoryItem]) {
    if let sessionId {
      session(sessionId).approvalHistory = approvals
    }
  }

  private func handleApprovalDeleted(_ approvalId: Int64) {
    for (_, obs) in _sessionObservables {
      obs.approvalHistory.removeAll { $0.id == approvalId }
    }
  }

  private func handleError(_ code: String, _ message: String, _ sessionId: String?) {
    netLog(.error, cat: .store, "Server error", sid: sessionId, data: ["code": code, "message": message])

    if code == "lagged" || code == "replay_oversized" {
      if let sessionId {
        let conv = conversation(sessionId)
        let obs = session(sessionId)
        Task {
          await conv.bootstrapFresh()
          syncConversationToObservable(conv, obs: obs)
        }
      }
      return
    }

    if code == "codex_auth_error" {
      codexAuthError = message
      return
    }

    lastServerError = (code: code, message: message)
  }

  private func handleConnectionStatusChanged(_ status: ConnectionStatus) {
    if status == .connected {
      hasReceivedInitialSessionsList = false
      eventStream.subscribeList()

      // Re-subscribe all active sessions
      for sessionId in subscribedSessions {
        let revision = lastRevision[sessionId]
        eventStream.subscribeSession(
          sessionId,
          sinceRevision: revision,
          includeSnapshot: true
        )
      }
    } else if status == .disconnected {
      hasReceivedInitialSessionsList = false
    }
  }

  // MARK: - Helpers

  private func syncConversationToObservable(_ conv: ConversationStore, obs: SessionObservable) {
    netLog(.debug, cat: .store, "Sync conversation → observable", sid: conv.sessionId, data: ["messageCount": conv.messages.count, "hasSnapshot": conv.hasReceivedInitialData])
    obs.messages = conv.messages
    obs.totalMessageCount = conv.totalMessageCount
    obs.oldestLoadedSequence = conv.oldestLoadedSequence
    obs.newestLoadedSequence = conv.newestLoadedSequence
    obs.hasMoreHistoryBefore = conv.hasMoreHistoryBefore
    obs.isLoadingOlderMessages = conv.isLoadingOlderMessages
    if conv.hasReceivedInitialData {
      obs.hasReceivedSnapshot = true
    }
    obs.bumpMessagesRevision()
  }

  private func hydrateObservable(_ obs: SessionObservable, from sess: Session) {
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

  private func updateSessionInList(_ session: Session) {
    var stamped = session
    stamped.endpointId = stamped.endpointId ?? endpointId
    stamped.endpointName = stamped.endpointName ?? endpointName
    if let idx = sessions.firstIndex(where: { $0.id == stamped.id }) {
      sessions[idx] = stamped
    } else {
      sessions.append(stamped)
    }
    notifySessionsChanged()
  }

  private func notifySessionsChanged() {
    NotificationCenter.default.post(name: .serverSessionsDidChange, object: nil)
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

  private func cacheConversationBeforeTrim(sessionId: String) {
    guard let conv = _conversationStores[sessionId], !conv.messages.isEmpty else { return }

    // LRU eviction
    if conversationCache.count >= kConversationCacheMax {
      if let oldest = conversationCache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
        conversationCache.removeValue(forKey: oldest)
      }
    }

    conversationCache[sessionId] = conv.cacheSnapshot()
  }

  private func trimInactiveSessionPayload(_ sessionId: String) {
    let obs = session(sessionId)
    obs.clearConversationPayloads()
    _conversationStores[sessionId]?.clear()
  }

  // MARK: - Codex Account Actions

  func refreshCodexAccount() {
    Task {
      do {
        let status = try await apiClient.readCodexAccount()
        codexAccountStatus = status
      } catch {
        netLog(.warning, cat: .store, "Refresh Codex account failed", data: ["error": error.localizedDescription])
      }
    }
  }

  func startCodexChatgptLogin() {
    Task {
      do {
        let resp = try await apiClient.startCodexLogin()
        if let url = URL(string: resp.authUrl) {
          _ = Platform.services.openURL(url)
        }
      } catch {
        codexAuthError = error.localizedDescription
      }
    }
  }

  func cancelCodexChatgptLogin() {
    guard let loginId = codexAccountStatus?.activeLoginId else { return }
    Task {
      do {
        try await apiClient.cancelCodexLogin(loginId: loginId)
      } catch {
        netLog(.warning, cat: .store, "Cancel Codex login failed", data: ["error": error.localizedDescription])
      }
    }
  }

  func logoutCodexAccount() {
    Task {
      do {
        let status = try await apiClient.logoutCodexAccount()
        codexAccountStatus = status
      } catch {
        codexAuthError = error.localizedDescription
      }
    }
  }
}
