//
//  SessionStore.swift
//  OrbitDock
//
//  Session list, per-session observables, and event routing.
//  All mutations go via APIClient (HTTP); events arrive from EventStream.
//

import Foundation

let kConversationCacheMax = 8

// MARK: - SessionStore

@Observable
@MainActor
final class SessionStore {
  let apiClient: APIClient
  let eventStream: EventStream
  let endpointId: UUID
  var endpointName: String?

  // MARK: - Observable state

  var sessions: [Session] = []
  var hasReceivedInitialSessionsList = false
  var codexModels: [ServerCodexModelOption] = []
  var claudeModels: [ServerClaudeModelOption] = []
  var codexAccountStatus: ServerCodexAccountStatus?
  var codexAuthError: String?
  var lastServerError: (code: String, message: String)?
  var worktreesByRepo: [String: [ServerWorktreeSummary]] = [:]
  var serverIsPrimary: Bool?
  var serverPrimaryClaims: [ServerClientPrimaryClaim] = []

  // MARK: - Per-session registries (not @Observable tracked)

  @ObservationIgnored var _sessionObservables: [String: SessionObservable] = [:]
  @ObservationIgnored var _conversationStores: [String: ConversationStore] = [:]
  @ObservationIgnored var conversationCache: [String: CachedConversation] = [:]

  // MARK: - Private tracking

  @ObservationIgnored var lastRevision: [String: UInt64] = [:]
  @ObservationIgnored var approvalPolicies: [String: String] = [:]
  @ObservationIgnored var sandboxModes: [String: String] = [:]
  @ObservationIgnored var permissionModes: [String: String] = [:]
  @ObservationIgnored var subscribedSessions: Set<String> = []
  @ObservationIgnored var autoMarkReadSessions: Set<String> = []
  @ObservationIgnored var inFlightApprovalDispatches: Set<String> = []
  @ObservationIgnored var eventProcessingTask: Task<Void, Never>?

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

  func subscribeToSession(
    _ sessionId: String,
    forceRefresh: Bool = false,
    recoveryGoal: ConversationRecoveryGoal = .coherentRecent
  ) {
    subscribedSessions.insert(sessionId)

    let conv = conversation(sessionId)

    if !forceRefresh, conv.hasReceivedInitialData {
      // Path 1: Retained snapshot — already have messages, just re-subscribe WS
      netLog(.info, cat: .store, "Subscribe: Path 1 — retained snapshot, re-subscribing WS", sid: sessionId)
      if recoveryGoal == .completeHistory {
        Task {
          _ = await conv.bootstrap(goal: recoveryGoal)
        }
      }
      eventStream.subscribeSession(
        sessionId,
        sinceRevision: nil,
        includeSnapshot: true
      )
    } else if !forceRefresh, let cached = conversationCache.removeValue(forKey: sessionId) {
      // Path 2: Cached messages — restore for instant display, subscribe for delta
      netLog(.info, cat: .store, "Subscribe: Path 2 — restoring from cache, WS + HTTP reconcile", sid: sessionId)
      conv.restoreFromCache(cached)
      eventStream.subscribeSession(
        sessionId,
        sinceRevision: lastRevision[sessionId],
        includeSnapshot: false
      )
      // Background reconcile via HTTP bootstrap
      Task {
        _ = await conv.bootstrap(goal: recoveryGoal)
      }
    } else {
      // Path 3: Bootstrap — fresh HTTP load, then subscribe
      netLog(.info, cat: .store, "Subscribe: Path 3 — fresh HTTP bootstrap", sid: sessionId)
      Task {
        let revision = await conv.bootstrap(goal: recoveryGoal)
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
        session(sessionId).approvalHistory = response.approvals
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
