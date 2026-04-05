import Foundation

@MainActor
extension SessionStore {
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
    let response = try await clients.controlDeck.submitTurn(sessionId, request: request)
    notifyConversationRowDelta(sessionId, ConversationRowDelta(
      upserted: [response.row],
      removedIds: []
    ))
    triggerLocalNamingIfNeeded(sessionId: sessionId, prompt: request.text)
    notifySessionChanged(sessionId)
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
    let response = try await clients.conversation.sendMessage(sessionId, request: request)
    notifyConversationRowDelta(sessionId, ConversationRowDelta(
      upserted: [response.row],
      removedIds: []
    ))
    notifySessionChanged(sessionId)
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
    notifyConversationRowDelta(sessionId, ConversationRowDelta(
      upserted: [response.row],
      removedIds: []
    ))
    notifySessionChanged(sessionId)
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
    grantRequestedPermissions: Bool,
    requestedPermissions: [ServerPermissionDescriptor]? = nil
  ) async throws {
    netLog(
      .info,
      cat: .store,
      "Respond to permission request",
      sid: sessionId,
      data: ["requestId": requestId, "scope": scope.rawValue]
    )
    var request = ApprovalsClient.RespondToPermissionRequestRequest(requestId: requestId)
    request.permissions = grantRequestedPermissions ? requestedPermissions : nil
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
    notifySessionChanged(sessionId)
    subscribeToSession(sessionId, forceRecovery: true)
  }

  func endSession(_ sessionId: String) async throws {
    netLog(.info, cat: .store, "End session", sid: sessionId)
    try await clients.sessions.endSession(sessionId)
  }

  func interruptSession(_ sessionId: String) async throws {
    netLog(.info, cat: .store, "Interrupt session", sid: sessionId)
    try await clients.conversation.interruptSession(sessionId)
  }

  func takeoverSession(
    _ sessionId: String,
    model: String?,
    approvalPolicy: String?,
    approvalPolicyDetails: ServerCodexApprovalPolicy?,
    sandboxMode: String?,
    permissionMode: String?,
    collaborationMode: String?,
    multiAgent: Bool?,
    personality: String?,
    serviceTier: String?,
    developerInstructions: String?
  ) async throws {
    let request = SessionsClient.TakeoverRequest(
      model: model,
      approvalPolicy: approvalPolicy,
      approvalPolicyDetails: approvalPolicyDetails,
      sandboxMode: sandboxMode,
      permissionMode: permissionMode,
      collaborationMode: collaborationMode,
      multiAgent: multiAgent,
      personality: personality,
      serviceTier: serviceTier,
      developerInstructions: developerInstructions
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
    var request = SessionsClient.ForkRequest()
    request.nthUserMessage = nthUserMessage
    _ = try await clients.sessions.forkSession(sessionId, request: request)
  }

  func forkSessionToWorktree(
    sessionId: String,
    branchName: String,
    baseBranch: String?,
    nthUserMessage: UInt32?
  ) async throws {
    var request = SessionsClient.ForkToWorktreeRequest(branchName: branchName)
    request.baseBranch = baseBranch
    request.nthUserMessage = nthUserMessage
    _ = try await clients.sessions.forkSessionToWorktree(sessionId, request: request)
  }

  func forkSessionToExistingWorktree(
    sessionId: String,
    worktreeId: String,
    nthUserMessage: UInt32?
  ) async throws {
    let request = SessionsClient.ForkToExistingWorktreeRequest(worktreeId: worktreeId, nthUserMessage: nthUserMessage)
    _ = try await clients.sessions.forkSessionToExistingWorktree(sessionId, request: request)
  }

  func compactContext(_ sessionId: String) async throws {
    try await clients.conversation.compactContext(sessionId)
  }

  func undoLastTurn(_ sessionId: String) async throws {
    try await clients.conversation.undoLastTurn(sessionId)
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

  func loadPermissionRules(sessionId: String) async throws -> ServerSessionPermissionRules {
    let response = try await clients.approvals.fetchPermissionRules(sessionId)
    return response.rules
  }

  func addPermissionRule(sessionId: String, pattern: String, behavior: String, scope: String) async throws {
    try await clients.approvals.addPermissionRule(
      sessionId: sessionId,
      pattern: pattern,
      behavior: behavior,
      scope: scope
    )
  }

  func removePermissionRule(sessionId: String, pattern: String, behavior: String, scope: String) async throws {
    try await clients.approvals.removePermissionRule(
      sessionId: sessionId,
      pattern: pattern,
      behavior: behavior,
      scope: scope
    )
  }

  func updateClaudePermissionMode(_ sessionId: String, mode: ClaudePermissionMode) async throws {
    try await updateSessionConfig(sessionId, permissionMode: mode.rawValue)
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
    // No-op: session state is now owned by per-surface view models
  }

  // MARK: - Local Conversation Naming

  private func triggerLocalNamingIfNeeded(sessionId: String, prompt: String) {
    guard LocalNamingAvailabilityResolver.current == .available else { return }
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
