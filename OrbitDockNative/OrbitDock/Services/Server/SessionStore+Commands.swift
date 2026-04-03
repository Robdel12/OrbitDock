import Foundation

@MainActor
extension SessionStore {
  // Compatibility-only command bridge.
  // Legacy/dead-end surface: do not route new feature work through this file.
  // Do not add new feature commands here.
  // New behavior belongs in feature-owned services/view models; keep this file
  // limited to forwarding that existing callers still depend on.
  func fetchControlDeckSnapshot(sessionId: String) async throws -> ServerControlDeckSnapshotPayload {
    try await clients.controlDeck.fetchSnapshot(sessionId)
  }

  func fetchControlDeckPreferences() async throws -> ServerControlDeckPreferences {
    try await clients.controlDeck.fetchPreferences()
  }

  func updateControlDeckPreferences(
    _ request: ServerControlDeckPreferences
  ) async throws -> ServerControlDeckPreferences {
    try await clients.controlDeck.updatePreferences(request)
  }

  func submitControlDeckTurn(
    sessionId: String,
    request: ServerControlDeckSubmitTurnRequest
  ) async throws {
    netLog(
      .info,
      cat: .store,
      "Submit Control Deck turn",
      sid: sessionId,
      data: [
        "textLength": request.text.count,
        "attachments": request.attachments.count,
        "skills": request.skills.count,
      ]
    )
    do {
      let response = try await clients.controlDeck.submitTurn(sessionId, request: request)
      session(sessionId).applyRowsChanged(upserted: [response.row], removedIds: [])
      triggerLocalNamingIfNeeded(sessionId: sessionId, prompt: request.text)
      await reconcileConversationState(sessionId: sessionId)
    } catch {
      netLog(
        .error,
        cat: .store,
        "Submit Control Deck turn failed",
        sid: sessionId,
        data: ["error": String(describing: error)]
      )
      throw error
    }
  }

  func sendMessage(
    sessionId: String,
    content: String,
    model: String? = nil,
    effort: String? = nil,
    skills: [ServerSkillInput] = [],
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) async throws {
    netLog(
      .info,
      cat: .store,
      "Send message",
      sid: sessionId,
      data: [
        "contentLength": content.count,
        "model": model ?? "-",
        "effort": effort ?? "-",
        "images": images.count,
        "mentions": mentions.count,
        "skills": skills.count,
      ]
    )
    var request = ConversationClient.SendMessageRequest(content: content)
    request.model = model
    request.effort = effort
    request.skills = skills
    request.images = images
    request.mentions = mentions
    do {
      let response = try await clients.conversation.sendMessage(sessionId, request: request)
      session(sessionId).applyRowsChanged(upserted: [response.row], removedIds: [])
      await reconcileConversationState(sessionId: sessionId)
    } catch {
      netLog(
        .error,
        cat: .store,
        "Send message failed",
        sid: sessionId,
        data: ["error": String(describing: error)]
      )
      throw error
    }

    triggerLocalNamingIfNeeded(sessionId: sessionId, prompt: content)
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
    let response = try await clients.conversation.steerTurn(sessionId, request: request)
    session(sessionId).applyRowsChanged(upserted: [response.row], removedIds: [])
    await reconcileConversationState(sessionId: sessionId)
  }

  func approveTool(
    sessionId: String,
    requestId: String,
    decision: ApprovalsClient.ToolApprovalDecision,
    message: String? = nil,
    interrupt: Bool? = nil
  ) async throws {
    netLog(
      .info,
      cat: .store,
      "Approve tool",
      sid: sessionId,
      data: ["requestId": requestId, "decision": decision.rawValue]
    )
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
    netLog(
      .info,
      cat: .store,
      "Respond to permission request",
      sid: sessionId,
      data: ["requestId": requestId, "scope": scope.rawValue]
    )
    let permissionsPayload: [ServerPermissionDescriptor]? = if grantRequestedPermissions,
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

  func createSession(_ request: SessionsClient.CreateSessionRequest) async throws -> SessionsClient
    .CreateSessionResponse
  {
    netLog(.info, cat: .store, "Create session", data: ["provider": request.provider, "cwd": request.cwd])
    return try await clients.sessions.createSession(request)
  }

  func resumeSession(_ sessionId: String) async throws {
    netLog(.info, cat: .store, "Resume session requested", sid: sessionId)
    let response = try await clients.sessions.resumeSession(sessionId)
    netLog(.info, cat: .store, "Resume session response received", sid: sessionId, data: [
      "status": response.session.status.rawValue,
      "workStatus": response.session.workStatus.rawValue,
      "controlMode": response.session.controlMode.rawValue,
      "lifecycleState": response.session.lifecycleState.rawValue,
      "acceptsUserInput": response.session.acceptsUserInput,
      "steerable": response.session.steerable,
    ])
    let obs = session(sessionId)
    obs.applyResumeSummary(response.session)
    netLog(.info, cat: .store, "Resume summary applied to observable", sid: sessionId, data: [
      "status": obs.status.rawValue,
      "workStatus": obs.workStatus.rawValue,
      "controlMode": obs.controlMode.rawValue,
      "lifecycleState": obs.lifecycleState.rawValue,
      "acceptsUserInput": obs.acceptsUserInput,
      "steerable": obs.steerable,
    ])
    // Resume can coincide with transient WS disconnects. Reassert subscription
    // so the active screen gets fresh bootstrap/state without requiring
    // dashboard navigation.
    subscribeToSession(sessionId, forceRecovery: true)
    await reconcileConversationState(sessionId: sessionId)
    netLog(.info, cat: .store, "Resume triggered session resubscribe", sid: sessionId)
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
    let approvalPolicyDetails: ServerCodexApprovalPolicy?
    let sandboxMode: String?
    if case let .codex(currentApprovalPolicy, currentApprovalPolicyDetails, currentSandboxMode) = currentRules {
      approvalPolicy = currentApprovalPolicy
      approvalPolicyDetails = currentApprovalPolicyDetails
      sandboxMode = currentSandboxMode
    } else {
      approvalPolicy = nil
      approvalPolicyDetails = nil
      sandboxMode = nil
    }

    let request = SessionsClient.TakeoverRequest(
      model: observable.model,
      approvalPolicy: approvalPolicy,
      approvalPolicyDetails: approvalPolicyDetails,
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

  func setSummary(_ sessionId: String, summary: String) async throws {
    try await clients.sessions.setSummary(sessionId, summary: summary)
  }

  func updateSessionConfig(
    _ sessionId: String,
    approvalPolicy: String? = nil,
    approvalPolicyDetails: ServerCodexApprovalPolicy? = nil,
    sandboxMode: String? = nil,
    approvalsReviewer: ServerCodexApprovalsReviewer? = nil,
    permissionMode: String? = nil,
    collaborationMode: String? = nil,
    multiAgent: Bool? = nil,
    personality: String? = nil,
    serviceTier: String? = nil,
    developerInstructions: String? = nil
  ) async throws {
    let config = SessionsClient.UpdateSessionConfigRequest(
      approvalPolicy: approvalPolicy,
      approvalPolicyDetails: approvalPolicyDetails,
      sandboxMode: sandboxMode,
      approvalsReviewer: approvalsReviewer,
      permissionMode: permissionMode,
      collaborationMode: collaborationMode,
      multiAgent: multiAgent,
      personality: personality,
      serviceTier: serviceTier,
      developerInstructions: developerInstructions
    )
    try await clients.sessions.updateSessionConfig(sessionId, config: config)
  }

  func updateCodexSessionOverrides(
    _ sessionId: String,
    configMode: ServerCodexConfigMode? = nil,
    configProfile: SessionsClient.OptionalStringPatch? = nil,
    modelProvider: SessionsClient.OptionalStringPatch? = nil,
    collaborationMode: SessionsClient.OptionalStringPatch? = nil,
    multiAgent: SessionsClient.OptionalBoolPatch? = nil,
    personality: SessionsClient.OptionalStringPatch? = nil,
    serviceTier: SessionsClient.OptionalStringPatch? = nil,
    developerInstructions: SessionsClient.OptionalStringPatch? = nil
  ) async throws {
    let config = SessionsClient.UpdateCodexSessionOverridesRequest(
      configMode: configMode,
      configProfile: configProfile,
      modelProvider: modelProvider,
      collaborationMode: collaborationMode,
      multiAgent: multiAgent,
      personality: personality,
      serviceTier: serviceTier,
      developerInstructions: developerInstructions
    )
    try await clients.sessions.updateCodexSessionOverrides(sessionId, config: config)
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
    session(sessionId).compactInProgress = true
    do {
      try await clients.conversation.compactContext(sessionId)
    } catch {
      session(sessionId).compactInProgress = false
      throw error
    }
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
    session(sessionId).rollbackInProgress = true
    do {
      try await clients.conversation.rollbackTurns(sessionId, numTurns: numTurns)
    } catch {
      session(sessionId).rollbackInProgress = false
      throw error
    }
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
    let obs = session(sessionId)
    guard !obs.isLoadingOlderMessages, obs.hasMoreHistoryBefore,
          let before = obs.oldestLoadedSequence
    else { return }
    guard lastOlderMessagesRequestBeforeSequence[sessionId] != before else {
      netLog(
        .debug,
        cat: .conv,
        "Skipping duplicate older-messages request",
        sid: sessionId,
        data: ["beforeSeq": before]
      )
      return
    }

    obs.isLoadingOlderMessages = true
    lastOlderMessagesRequestBeforeSequence[sessionId] = before
    netLog(.info, cat: .conv, "Loading older messages", sid: sessionId, data: ["beforeSeq": before])

    Task {
      defer { obs.isLoadingOlderMessages = false }
      do {
        let page = try await clients.conversation.fetchConversationHistory(
          sessionId, beforeSequence: before, limit: limit
        )
        obs.applyConversationPage(
          rows: page.rows,
          hasMoreBefore: page.hasMoreBefore,
          oldestSequence: page.oldestSequence
        )
      } catch {
        lastOlderMessagesRequestBeforeSequence.removeValue(forKey: sessionId)
        netLog(
          .error,
          cat: .conv,
          "Load older messages failed",
          sid: sessionId,
          data: ["error": error.localizedDescription]
        )
      }
    }
  }

  func uploadControlDeckImageAttachment(
    sessionId: String,
    data: Data,
    mimeType: String,
    displayName: String,
    pixelWidth: Int?,
    pixelHeight: Int?
  ) async throws -> ServerControlDeckImageAttachmentRef {
    try await clients.controlDeck.uploadImageAttachment(
      sessionId: sessionId,
      data: data,
      mimeType: mimeType,
      displayName: displayName,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
  }

  func uploadImageAttachment(
    sessionId: String,
    data: Data,
    mimeType: String,
    displayName: String,
    pixelWidth: Int?,
    pixelHeight: Int?
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

  func listReviewComments(sessionId: String, turnId: String?) async throws {
    let response = try await clients.approvals.listReviewComments(sessionId: sessionId, turnId: turnId)
    session(sessionId).reviewComments = response.comments
  }

  func worktrees(for repoRoot: String) -> [ServerWorktreeSummary] {
    worktreesByRepo[repoRoot] ?? []
  }

  func clearServerError() {
    lastServerError = nil
  }

  func refreshCodexModels() {
    Task { codexModels = await (try? clients.usage.listCodexModels()) ?? codexModels }
  }

  func handleMemoryPressure() {
    for (_, observable) in _sessionObservables where !subscribedSessions.contains(observable.id) {
      observable.trimInactiveDetailPayloads()
    }
  }

  private func reconcileConversationState(sessionId: String) async {
    _ = await hydrateSessionFromHTTPBootstrap(sessionId: sessionId)
  }

  // MARK: - Local Conversation Naming

  private func triggerLocalNamingIfNeeded(sessionId: String, prompt: String) {
    guard LocalNamingAvailabilityResolver.current == .available else { return }

    let obs = session(sessionId)
    guard obs.customName == nil, obs.summary == nil else { return }
    guard _localNamingClaimedSessions.insert(sessionId).inserted else { return }

    Task {
      #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
          guard let name = await LocalConversationNamingService.generateTitle(from: prompt) else {
            return
          }
          try? await setSummary(sessionId, summary: name)
        }
      #endif
    }
  }
}
