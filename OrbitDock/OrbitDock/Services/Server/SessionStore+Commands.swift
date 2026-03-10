import Foundation

@MainActor
extension SessionStore {
  func sendMessage(
    sessionId: String,
    content: String,
    model: String? = nil,
    effort: String? = nil,
    skills: [ServerSkillInput] = [],
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
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
    sessionId: String,
    content: String,
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) async throws {
    var request = APIClient.SteerTurnRequest(content: content)
    request.images = images
    request.mentions = mentions
    try await apiClient.steerTurn(sessionId, request: request)
  }

  func approveTool(
    sessionId: String,
    requestId: String,
    decision: String,
    message: String? = nil,
    interrupt: Bool? = nil
  ) async throws {
    netLog(.info, cat: .store, "Approve tool", sid: sessionId, data: ["requestId": requestId, "decision": decision])
    var request = APIClient.ApproveToolRequest(requestId: requestId, decision: decision)
    request.message = message
    request.interrupt = interrupt
    _ = try await apiClient.approveTool(sessionId, request: request)
  }

  func answerQuestion(
    sessionId: String,
    requestId: String,
    answer: String,
    questionId: String? = nil,
    answers: [String: [String]] = [:]
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
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
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
    sessionId: String,
    branchName: String,
    baseBranch: String?,
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
    sessionId: String,
    worktreeId: String,
    nthUserMessage: UInt32?
  ) async throws {
    session(sessionId).forkInProgress = true
    do {
      let request = APIClient.ForkToExistingWorktreeRequest(worktreeId: worktreeId, nthUserMessage: nthUserMessage)
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
    sessionId: String,
    data: Data,
    mimeType: String,
    displayName: String,
    pixelWidth: Int,
    pixelHeight: Int
  ) async throws -> ServerImageInput {
    try await apiClient.uploadImageAttachment(
      sessionId: sessionId,
      data: data,
      mimeType: mimeType,
      displayName: displayName,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
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

  func addPermissionRule(sessionId: String, pattern: String, behavior: String, scope: String) async throws {
    try await apiClient.addPermissionRule(
      sessionId: sessionId,
      pattern: pattern,
      behavior: behavior,
      scope: scope
    )
    _ = try await loadPermissionRules(sessionId: sessionId, forceRefresh: true)
  }

  func removePermissionRule(sessionId: String, pattern: String, behavior: String, scope: String) async throws {
    try await apiClient.removePermissionRule(
      sessionId: sessionId,
      pattern: pattern,
      behavior: behavior,
      scope: scope
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

  func nextPendingApprovalRequestId(sessionId: String) -> String? {
    session(sessionId).pendingApproval?.id
  }

  func pendingApprovalType(sessionId: String, requestId: String) -> ServerApprovalType? {
    guard let approval = session(sessionId).pendingApproval,
          approval.id == requestId else { return nil }
    return approval.type
  }

  func listSkills(sessionId: String) async throws {
    let response = try await apiClient.listSkills(sessionId: sessionId)
    session(sessionId).skills = response.skills.flatMap(\.skills)
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
          let worktrees = try await apiClient.listWorktrees(repoRoot: root)
          worktreesByRepo[root] = worktrees
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

  var isRemoteConnection: Bool {
    eventStream.isRemote
  }

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
}
