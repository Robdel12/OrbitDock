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
    var request = ConversationClient.SendMessageRequest(content: content)
    request.model = model
    request.effort = effort
    request.skills = skills
    request.images = images
    request.mentions = mentions
    let message = try await clients.conversation.sendMessage(sessionId, request: request)
    handleMessageAppended(sessionId, message)
  }

  func steerTurn(
    sessionId: String,
    content: String,
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) async throws {
    var request = ConversationClient.SteerTurnRequest(content: content)
    request.images = images
    request.mentions = mentions
    try await clients.conversation.steerTurn(sessionId, request: request)
  }

  func approveTool(
    sessionId: String,
    requestId: String,
    decision: String,
    message: String? = nil,
    interrupt: Bool? = nil
  ) async throws {
    netLog(.info, cat: .store, "Approve tool", sid: sessionId, data: ["requestId": requestId, "decision": decision])
    var request = ApprovalsClient.ApproveToolRequest(requestId: requestId, decision: decision)
    request.message = message
    request.interrupt = interrupt
    _ = try await clients.approvals.approveTool(sessionId, request: request)
  }

  func answerQuestion(
    sessionId: String,
    requestId: String,
    answer: String,
    questionId: String? = nil,
    answers: [String: [String]] = [:]
  ) async throws {
    netLog(.info, cat: .store, "Answer question", sid: sessionId, data: ["requestId": requestId])
    var request = ApprovalsClient.AnswerQuestionRequest(requestId: requestId, answer: answer)
    request.questionId = questionId
    request.answers = answers
    _ = try await clients.approvals.answerQuestion(sessionId, request: request)
  }

  func respondToPermissionRequest(
    sessionId: String,
    requestId: String,
    scope: ServerPermissionGrantScope,
    grantRequestedPermissions: Bool
  ) async throws {
    netLog(.info, cat: .store, "Respond to permission request", sid: sessionId, data: ["requestId": requestId, "scope": scope.rawValue])
    let permissionsPayload: AnyCodable? = if grantRequestedPermissions,
      let approval = session(sessionId).pendingApproval,
      approval.id == requestId
    {
      approval.requestedPermissions
    } else {
      nil
    }

    var request = ApprovalsClient.RespondToPermissionRequestRequest(requestId: requestId)
    request.permissions = permissionsPayload
    request.scope = scope
    _ = try await clients.approvals.respondToPermissionRequest(sessionId, request: request)
  }

  func createSession(_ request: SessionsClient.CreateSessionRequest) async throws -> SessionsClient.CreateSessionResponse {
    netLog(.info, cat: .store, "Create session", data: ["provider": request.provider, "cwd": request.cwd])
    return try await clients.sessions.createSession(request)
  }

  func resumeSession(_ sessionId: String) async throws {
    _ = try await clients.sessions.resumeSession(sessionId)
  }

  func endSession(_ sessionId: String) async throws {
    netLog(.info, cat: .store, "End session", sid: sessionId)
    try await clients.sessions.endSession(sessionId)
  }

  func interruptSession(_ sessionId: String) async throws {
    netLog(.info, cat: .store, "Interrupt session", sid: sessionId)
    try await clients.conversation.interruptSession(sessionId)
  }

  func takeoverSession(_ sessionId: String) async throws {
    let observable = session(sessionId)
    let currentRules = observable.permissionRules

    let approvalPolicy: String?
    let sandboxMode: String?
    if case let .codex(currentApprovalPolicy, currentSandboxMode) = currentRules {
      approvalPolicy = currentApprovalPolicy
      sandboxMode = currentSandboxMode
    } else {
      approvalPolicy = nil
      sandboxMode = nil
    }

    let request = SessionsClient.TakeoverRequest(
      model: observable.model,
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      permissionMode: observable.provider == .claude ? observable.permissionMode.rawValue : nil,
      collaborationMode: observable.collaborationMode,
      multiAgent: observable.multiAgent,
      personality: observable.personality,
      serviceTier: observable.serviceTier,
      developerInstructions: observable.developerInstructions
    )
    _ = try await clients.sessions.takeoverSession(sessionId, request: request)
  }

  func renameSession(_ sessionId: String, name: String?) async throws {
    try await clients.sessions.renameSession(sessionId, name: name)
  }

  func updateSessionConfig(
    _ sessionId: String,
    approvalPolicy: String? = nil,
    sandboxMode: String? = nil,
    permissionMode: String? = nil,
    collaborationMode: String? = nil,
    multiAgent: Bool? = nil,
    personality: String? = nil,
    serviceTier: String? = nil,
    developerInstructions: String? = nil
  ) async throws {
    let config = SessionsClient.UpdateSessionConfigRequest(
      approvalPolicy: approvalPolicy,
      sandboxMode: sandboxMode,
      permissionMode: permissionMode,
      collaborationMode: collaborationMode,
      multiAgent: multiAgent,
      personality: personality,
      serviceTier: serviceTier,
      developerInstructions: developerInstructions
    )
    try await clients.sessions.updateSessionConfig(sessionId, config: config)
  }

  func forkSession(sessionId: String, nthUserMessage: UInt32?) async throws {
    session(sessionId).forkInProgress = true
    do {
      var request = SessionsClient.ForkRequest()
      request.nthUserMessage = nthUserMessage
      _ = try await clients.sessions.forkSession(sessionId, request: request)
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
      var request = SessionsClient.ForkToWorktreeRequest(branchName: branchName)
      request.baseBranch = baseBranch
      request.nthUserMessage = nthUserMessage
      _ = try await clients.sessions.forkSessionToWorktree(sessionId, request: request)
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
      let request = SessionsClient.ForkToExistingWorktreeRequest(worktreeId: worktreeId, nthUserMessage: nthUserMessage)
      _ = try await clients.sessions.forkSessionToExistingWorktree(sessionId, request: request)
    } catch {
      session(sessionId).forkInProgress = false
      throw error
    }
  }

  func compactContext(_ sessionId: String) async throws {
    try await clients.conversation.compactContext(sessionId)
  }

  func undoLastTurn(_ sessionId: String) async throws {
    session(sessionId).undoInProgress = true
    do {
      try await clients.conversation.undoLastTurn(sessionId)
    } catch {
      session(sessionId).undoInProgress = false
      throw error
    }
  }

  func rollbackTurns(_ sessionId: String, numTurns: UInt32) async throws {
    try await clients.conversation.rollbackTurns(sessionId, numTurns: numTurns)
  }

  func rewindFiles(_ sessionId: String, userMessageId: String) async throws {
    try await clients.conversation.rewindFiles(sessionId, userMessageId: userMessageId)
  }

  func stopTask(_ sessionId: String, taskId: String) async throws {
    try await clients.conversation.stopTask(sessionId, taskId: taskId)
  }

  func executeShell(_ sessionId: String, command: String) async throws {
    try await clients.conversation.executeShell(sessionId: sessionId, command: command)
  }

  func cancelShell(_ sessionId: String, requestId: String) async throws {
    try await clients.conversation.cancelShell(sessionId: sessionId, requestId: requestId)
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
        let newCount = try await clients.sessions.markSessionRead(sessionId)
        session(sessionId).unreadCount = newCount
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
          sessions[idx].unreadCount = newCount
          updateRootSessionInList(sessions[idx].toRootSessionRecord())
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
    try await clients.conversation.uploadImageAttachment(
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
    let response = try await clients.approvals.fetchPermissionRules(sessionId)
    obs.permissionRules = response.rules
    return response.rules
  }

  func addPermissionRule(sessionId: String, pattern: String, behavior: String, scope: String) async throws {
    try await clients.approvals.addPermissionRule(
      sessionId: sessionId,
      pattern: pattern,
      behavior: behavior,
      scope: scope
    )
    _ = try await loadPermissionRules(sessionId: sessionId, forceRefresh: true)
  }

  func removePermissionRule(sessionId: String, pattern: String, behavior: String, scope: String) async throws {
    try await clients.approvals.removePermissionRule(
      sessionId: sessionId,
      pattern: pattern,
      behavior: behavior,
      scope: scope
    )
    _ = try await loadPermissionRules(sessionId: sessionId, forceRefresh: true)
  }

  func updateClaudePermissionMode(_ sessionId: String, mode: ClaudePermissionMode) async throws {
    try await updateSessionConfig(sessionId, permissionMode: mode.rawValue)
    applyLocalPermissionMode(mode, sessionId: sessionId)
  }

  func getSubagentTools(sessionId: String, subagentId: String) {
    Task {
      let tools = try await clients.sessions.getSubagentTools(sessionId: sessionId, subagentId: subagentId)
      session(sessionId).subagentTools[subagentId] = tools
    }
  }

  func getSubagentMessages(sessionId: String, subagentId: String) {
    Task {
      let messages = try await clients.sessions.getSubagentMessages(sessionId: sessionId, subagentId: subagentId)
      session(sessionId).subagentMessages[subagentId] = messages
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
    let response = try await clients.skills.listSkills(sessionId: sessionId)
    session(sessionId).skills = response.skills.flatMap(\.skills)
  }

  func listMcpTools(sessionId: String) async throws {
    let response = try await clients.mcp.listTools(sessionId: sessionId)
    let obs = session(sessionId)
    obs.mcpTools = response.tools
    obs.mcpResources = response.resources
    obs.mcpResourceTemplates = response.resourceTemplates
    obs.mcpAuthStatuses = response.authStatuses
  }

  func refreshMcpServers(_ sessionId: String) async throws {
    try await clients.mcp.refreshServers(sessionId: sessionId)
  }

  func listReviewComments(sessionId: String, turnId: String?) async throws {
    let response = try await clients.approvals.listReviewComments(sessionId: sessionId, turnId: turnId)
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
          let worktrees = try await clients.worktrees.listWorktrees(repoRoot: root)
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
    Task { codexModels = (try? await clients.usage.listCodexModels()) ?? codexModels }
  }

  func refreshClaudeModels() {
    Task { claudeModels = (try? await clients.usage.listClaudeModels()) ?? claudeModels }
  }

  func handleMemoryPressure() {
    conversationCache.removeAll()
    for (id, _) in _conversationStores where !subscribedSessions.contains(id) {
      _conversationStores[id]?.clear()
      _conversationStores.removeValue(forKey: id)
    }
  }
}
