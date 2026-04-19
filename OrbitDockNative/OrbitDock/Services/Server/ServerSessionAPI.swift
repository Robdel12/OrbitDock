import Foundation

@MainActor
final class ServerSessionAPI {
  struct ConversationMutationResult {
    let row: ServerConversationRowEntry
    let sessionDetailSnapshot: ServerSessionDetailSnapshotPayload?
  }

  let sessionId: String
  @ObservationIgnored let endpointRuntime: ServerEndpointRuntime
  @ObservationIgnored let transport: ServerSessionTransport

  @ObservationIgnored var localNamingState = LocalConversationNamingSessionState()
  @ObservationIgnored var localNamingClaimed = false
  @ObservationIgnored var localNamingInFlight = false
  @ObservationIgnored var localNamingAvailabilityOverride: LocalNamingAvailability?
  @ObservationIgnored var localTitleGenerator: LocalConversationTitleGenerator?
  @ObservationIgnored private var detailSnapshotTask: Task<ServerSessionDetailSnapshotPayload, Error>?
  @ObservationIgnored private var lastDetailSnapshot: ServerSessionDetailSnapshotPayload?

  init(
    sessionId: String,
    endpointRuntime: ServerEndpointRuntime,
    transport: ServerSessionTransport
  ) {
    self.sessionId = sessionId
    self.endpointRuntime = endpointRuntime
    self.transport = transport
  }

  var clients: ServerClients {
    endpointRuntime.clients
  }

  func fetchConversationBootstrap(
    limit: Int,
    source: String
  ) async throws -> ServerConversationBootstrap {
    try await clients.conversation.fetchConversationBootstrap(
      sessionId,
      limit: limit,
      source: source
    )
  }

  func fetchSessionDetail() async throws -> ServerSessionDetailSnapshotPayload {
    if let detailSnapshotTask {
      return try await detailSnapshotTask.value
    }

    let task = Task { [clients, sessionId] in
      try await clients.conversation.fetchSessionDetail(sessionId)
    }
    detailSnapshotTask = task
    defer {
      if detailSnapshotTask == task {
        detailSnapshotTask = nil
      }
    }

    do {
      let payload = try await task.value
      lastDetailSnapshot = payload
      return payload
    } catch {
      throw error
    }
  }

  func fetchConversationHistory(
    beforeSequence: UInt64,
    limit: Int
  ) async throws -> ServerConversationHistoryPage {
    try await clients.conversation.fetchConversationHistory(
      sessionId,
      beforeSequence: beforeSequence,
      limit: limit
    )
  }

  func fetchReviewSnapshot() async throws -> ServerSessionReviewSnapshotPayload {
    try await clients.review.fetchSnapshot(sessionId)
  }

  func createReviewComment(
    request: ApprovalsClient.CreateReviewCommentRequest
  ) async throws -> ApprovalsClient.ReviewCommentMutationResponse {
    try await clients.approvals.createReviewComment(sessionId: sessionId, request: request)
  }

  func updateReviewComment(
    commentId: String,
    body: ApprovalsClient.UpdateReviewCommentRequest
  ) async throws -> ApprovalsClient.ReviewCommentMutationResponse {
    try await clients.approvals.updateReviewComment(commentId: commentId, body: body)
  }

  func listSkills(forceReload: Bool = false) async throws -> SkillsClient.SkillsResponse {
    try await clients.skills.listSkills(sessionId: sessionId, forceReload: forceReload)
  }

  func fetchSubagentTools(subagentId: String) async throws -> [ServerSubagentTool] {
    try await clients.sessions.getSubagentTools(sessionId: sessionId, subagentId: subagentId)
  }

  func fetchSubagentMessages(subagentId: String) async throws -> [ServerConversationRowEntry] {
    try await clients.sessions.getSubagentMessages(sessionId: sessionId, subagentId: subagentId)
  }

  func removeWorktree(
    worktreeId: String,
    force: Bool,
    deleteBranch: Bool
  ) async throws {
    try await clients.worktrees.removeWorktree(
      worktreeId: worktreeId,
      force: force,
      deleteBranch: deleteBranch
    )
  }

  func listCodexModels() async throws -> [ServerCodexModelOption] {
    try await clients.usage.listCodexModels()
  }

  func sendMessage(
    content: String,
    model: String? = nil,
    effort: String? = nil,
    skills: [ServerSkillInput] = [],
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) async throws -> ConversationMutationResult {
    var request = ConversationClient.SendMessageRequest(content: content)
    request.model = model
    request.effort = effort
    request.skills = skills
    request.images = images
    request.mentions = mentions
    let response = try await clients.conversation.sendMessage(sessionId, request: request)
    let detailSnapshot = adoptMutationDetailSnapshot(response.sessionDetailSnapshot, fallbackSurfaces: [.detail])
    transport.emitConversationRows(.init(upserted: [response.row], removedIds: []))
    transport.invalidate([.conversation])
    triggerLocalNamingIfNeeded(prompt: content)
    return ConversationMutationResult(
      row: response.row,
      sessionDetailSnapshot: detailSnapshot
    )
  }

  func steerTurn(
    content: String,
    images: [ServerImageInput] = [],
    mentions: [ServerMentionInput] = []
  ) async throws -> ConversationMutationResult {
    var request = ConversationClient.SteerTurnRequest(content: content)
    request.images = images
    request.mentions = mentions
    let response = try await clients.conversation.steerTurn(sessionId, request: request)
    let detailSnapshot = adoptMutationDetailSnapshot(response.sessionDetailSnapshot, fallbackSurfaces: [.detail])
    transport.emitConversationRows(.init(upserted: [response.row], removedIds: []))
    transport.invalidate([.conversation])
    return ConversationMutationResult(
      row: response.row,
      sessionDetailSnapshot: detailSnapshot
    )
  }

  func approveTool(
    requestId: String,
    decision: ApprovalsClient.ToolApprovalDecision,
    message: String? = nil,
    interrupt: Bool? = nil,
    updatedInput: AnyCodable? = nil
  ) async throws -> ApprovalsClient.ApprovalDecisionResponse {
    var request = ApprovalsClient.ApproveToolRequest(requestId: requestId, decision: decision)
    request.message = message
    request.interrupt = interrupt
    request.updatedInput = updatedInput
    return try await clients.approvals.approveTool(sessionId, request: request)
  }

  func answerQuestion(
    requestId: String,
    answer: String,
    questionId: String? = nil,
    answers: [String: [String]] = [:]
  ) async throws -> ApprovalsClient.ApprovalDecisionResponse {
    var request = ApprovalsClient.AnswerQuestionRequest(requestId: requestId, answer: answer)
    request.questionId = questionId
    request.answers = answers
    return try await clients.approvals.answerQuestion(sessionId, request: request)
  }

  func respondToPermissionRequest(
    requestId: String,
    scope: ServerPermissionGrantScope,
    grantRequestedPermissions: Bool,
    requestedPermissions: [ServerPermissionDescriptor]? = nil
  ) async throws -> ApprovalsClient.ApprovalDecisionResponse {
    var request = ApprovalsClient.RespondToPermissionRequestRequest(requestId: requestId)
    request.permissions = grantRequestedPermissions ? requestedPermissions : nil
    request.scope = scope
    return try await clients.approvals.respondToPermissionRequest(sessionId, request: request)
  }

  func resumeSession() async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.sessions.resumeSession(sessionId)
    return adoptMutationDetailSnapshot(response.sessionDetailSnapshot, fallbackSurfaces: [.detail])
  }

  func endSession() async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.sessions.endSession(sessionId)
    return adoptMutationDetailSnapshot(response.sessionDetailSnapshot, fallbackSurfaces: [.detail])
  }

  func interruptSession() async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.conversation.interruptSession(sessionId)
    transport.recordRevision(response.sessionDetailSnapshot?.revision)
    if response.sessionDetailSnapshot == nil {
      transport.invalidate([.detail])
    }
    return response.sessionDetailSnapshot
  }

  func takeoverSession(
    model: String?,
    approvalPolicyDetails: ServerCodexApprovalPolicy?,
    sandboxPolicyDetails: ServerCodexSandboxPolicy?,
    permissionMode: String?,
    collaborationMode: String?,
    multiAgent: Bool?,
    personality: String?,
    serviceTier: String?,
    developerInstructions: String?
  ) async throws -> ServerSessionDetailSnapshotPayload? {
    let request = SessionsClient.TakeoverRequest(
      model: model,
      approvalPolicyDetails: approvalPolicyDetails,
      sandboxPolicyDetails: sandboxPolicyDetails,
      permissionMode: permissionMode,
      collaborationMode: collaborationMode,
      multiAgent: multiAgent,
      personality: personality,
      serviceTier: serviceTier,
      developerInstructions: developerInstructions
    )
    let response = try await clients.sessions.takeoverSession(sessionId, request: request)
    return adoptMutationDetailSnapshot(response.sessionDetailSnapshot, fallbackSurfaces: [.detail])
  }

  func renameSession(name: String?) async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.sessions.renameSession(sessionId, name: name)
    updateLocalNamingState { state in
      state.customName = LocalConversationNamingPlanner.cleanOptionalText(name)
    }
    return adoptMutationDetailSnapshot(response.sessionDetailSnapshot, fallbackSurfaces: [.detail])
  }

  func setSummary(_ summary: String) async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.sessions.setSummary(sessionId, summary: summary)
    updateLocalNamingState { state in
      state.summary = LocalConversationNamingPlanner.cleanOptionalText(summary)
    }
    return adoptMutationDetailSnapshot(response.sessionDetailSnapshot, fallbackSurfaces: [.detail])
  }

  func updateSessionConfig(
    approvalPolicyDetails: ServerCodexApprovalPolicy? = nil,
    sandboxPolicyDetails: ServerCodexSandboxPolicy? = nil,
    approvalsReviewer: ServerCodexApprovalsReviewer? = nil,
    permissionMode: String? = nil,
    collaborationMode: String? = nil,
    multiAgent: Bool? = nil,
    personality: String? = nil,
    serviceTier: String? = nil,
    developerInstructions: String? = nil,
    model: String? = nil,
    effort: String? = nil
  ) async throws -> ServerSessionDetailSnapshotPayload {
    let config = SessionsClient.UpdateSessionConfigRequest(
      approvalPolicyDetails: approvalPolicyDetails,
      sandboxPolicyDetails: sandboxPolicyDetails,
      approvalsReviewer: approvalsReviewer,
      permissionMode: permissionMode,
      collaborationMode: collaborationMode,
      multiAgent: multiAgent,
      personality: personality,
      serviceTier: serviceTier,
      developerInstructions: developerInstructions,
      model: model,
      effort: effort
    )
    let payload = try await clients.sessions.updateSessionConfig(sessionId, config: config)
    transport.recordRevision(payload.revision)
    lastDetailSnapshot = payload
    return payload
  }

  func updateCodexSessionOverrides(
    configMode: ServerCodexConfigMode? = nil,
    configProfile: SessionsClient.OptionalStringPatch? = nil,
    modelProvider: SessionsClient.OptionalStringPatch? = nil,
    collaborationMode: SessionsClient.OptionalStringPatch? = nil,
    multiAgent: SessionsClient.OptionalBoolPatch? = nil,
    personality: SessionsClient.OptionalStringPatch? = nil,
    serviceTier: SessionsClient.OptionalStringPatch? = nil,
    developerInstructions: SessionsClient.OptionalStringPatch? = nil
  ) async throws -> ServerSessionDetailSnapshotPayload? {
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
    let payload = try await clients.sessions.updateCodexSessionOverrides(sessionId, config: config)
    transport.recordRevision(payload.revision)
    lastDetailSnapshot = payload
    return payload
  }

  func forkSession(nthUserMessage: UInt32?) async throws {
    var request = SessionsClient.ForkRequest()
    request.nthUserMessage = nthUserMessage
    let response = try await clients.sessions.forkSession(sessionId, request: request)
    endpointRuntime.requestSelection(
      SessionRef(endpointId: endpointRuntime.endpointId, sessionId: response.newSessionId)
    )
  }

  func forkSessionToWorktree(
    branchName: String,
    baseBranch: String?,
    nthUserMessage: UInt32?
  ) async throws {
    var request = SessionsClient.ForkToWorktreeRequest(branchName: branchName)
    request.baseBranch = baseBranch
    request.nthUserMessage = nthUserMessage
    let response = try await clients.sessions.forkSessionToWorktree(sessionId, request: request)
    endpointRuntime.requestSelection(
      SessionRef(endpointId: endpointRuntime.endpointId, sessionId: response.newSessionId)
    )
  }

  func forkSessionToExistingWorktree(
    worktreeId: String,
    nthUserMessage: UInt32?
  ) async throws {
    let request = SessionsClient.ForkToExistingWorktreeRequest(worktreeId: worktreeId, nthUserMessage: nthUserMessage)
    let response = try await clients.sessions.forkSessionToExistingWorktree(sessionId, request: request)
    endpointRuntime.requestSelection(
      SessionRef(endpointId: endpointRuntime.endpointId, sessionId: response.newSessionId)
    )
  }

  func compactContext() async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.conversation.compactContext(sessionId)
    transport.recordRevision(response.sessionDetailSnapshot?.revision)
    transport.invalidate([.conversation, .detail, .review])
    return response.sessionDetailSnapshot
  }

  func undoLastTurn() async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.conversation.undoLastTurn(sessionId)
    transport.recordRevision(response.sessionDetailSnapshot?.revision)
    transport.invalidate([.conversation, .detail, .review])
    return response.sessionDetailSnapshot
  }

  func rollbackTurns(numTurns: UInt32) async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.conversation.rollbackTurns(sessionId, numTurns: numTurns)
    transport.recordRevision(response.sessionDetailSnapshot?.revision)
    transport.invalidate([.conversation, .detail, .review])
    return response.sessionDetailSnapshot
  }

  func rewindFiles(userMessageId: String) async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.conversation.rewindFiles(sessionId, userMessageId: userMessageId)
    transport.recordRevision(response.sessionDetailSnapshot?.revision)
    transport.invalidate([.conversation, .detail, .review])
    return response.sessionDetailSnapshot
  }

  func stopTask(taskId: String) async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.conversation.stopTask(sessionId, taskId: taskId)
    transport.recordRevision(response.sessionDetailSnapshot?.revision)
    if response.sessionDetailSnapshot == nil {
      transport.invalidate([.detail])
    }
    return response.sessionDetailSnapshot
  }

  func uploadImageAttachment(
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

  func loadPermissionRules() async throws -> ServerSessionPermissionRules {
    let response = try await clients.approvals.fetchPermissionRules(sessionId)
    return response.rules
  }

  func addPermissionRule(
    pattern: String,
    behavior: String,
    scope: String
  ) async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.approvals.addPermissionRule(
      sessionId: sessionId,
      pattern: pattern,
      behavior: behavior,
      scope: scope
    )
    return adoptMutationDetailSnapshot(response.sessionDetailSnapshot, fallbackSurfaces: [.detail])
  }

  func removePermissionRule(
    pattern: String,
    behavior: String,
    scope: String
  ) async throws -> ServerSessionDetailSnapshotPayload? {
    let response = try await clients.approvals.removePermissionRule(
      sessionId: sessionId,
      pattern: pattern,
      behavior: behavior,
      scope: scope
    )
    return adoptMutationDetailSnapshot(response.sessionDetailSnapshot, fallbackSurfaces: [.detail])
  }

  func executeShell(command: String) async throws {
    try await clients.conversation.executeShell(sessionId: sessionId, command: command)
  }

  func cancelShell(requestId: String) async throws {
    try await clients.conversation.cancelShell(sessionId: sessionId, requestId: requestId)
  }

  func updateClaudePermissionMode(_ mode: ClaudePermissionMode) async throws {
    _ = try await updateSessionConfig(permissionMode: mode.rawValue)
  }

  func rememberLocalNamingState(_ session: ServerSessionState) {
    cacheLocalNamingState(LocalConversationNamingSessionState(session: session))
  }

  private func cacheLocalNamingState(_ state: LocalConversationNamingSessionState) {
    localNamingState = state
    if state.hasResolvedTitle {
      localNamingClaimed = true
    }
  }

  private func triggerLocalNamingIfNeeded(prompt: String) {
    let availability = localNamingAvailabilityOverride ?? LocalNamingAvailabilityResolver.current
    guard availability == .available else { return }
    guard !localNamingClaimed else { return }
    guard !localNamingInFlight else { return }
    localNamingInFlight = true

    Task {
      defer { localNamingInFlight = false }

      guard let context = await localNamingContextIfEligible(prompt: prompt) else {
        return
      }

      guard let name = await generateLocalTitle(for: context) else {
        return
      }
      guard await localNamingContextIfEligible(prompt: context.firstPrompt) != nil else {
        return
      }
      do {
        _ = try await setSummary(name)
      } catch {
        netLog(
          .error,
          cat: .store,
          "Local conversation naming summary update failed",
          sid: sessionId,
          data: ["error": error.localizedDescription]
        )
      }
    }
  }

  private func localNamingContextIfEligible(
    prompt: String
  ) async -> LocalConversationNamingContext? {
    let state = await authoritativeLocalNamingState()
    let decision = LocalConversationNamingPlanner.decision(prompt: prompt, sessionState: state)
    switch decision {
      case let .skip(claimSession):
        if claimSession {
          localNamingClaimed = true
        }
        return nil
      case let .generate(context):
        return context
    }
  }

  private func authoritativeLocalNamingState() async -> LocalConversationNamingSessionState? {
    if localNamingState.firstPrompt != nil || localNamingState.summary != nil || localNamingState.customName != nil {
      return localNamingState
    }

    if let lastDetailSnapshot {
      rememberLocalNamingState(lastDetailSnapshot.session)
      return localNamingState
    }

    do {
      let snapshot = try await fetchSessionDetail()
      rememberLocalNamingState(snapshot.session)
      return localNamingState
    } catch {
      return nil
    }
  }

  private func updateLocalNamingState(
    _ update: (inout LocalConversationNamingSessionState) -> Void
  ) {
    var state = localNamingState
    update(&state)
    cacheLocalNamingState(state)
  }

  private func generateLocalTitle(for context: LocalConversationNamingContext) async -> String? {
    if let generator = localTitleGenerator {
      return await generator(context)
    }

    #if canImport(FoundationModels)
      if #available(macOS 26.0, iOS 26.0, *) {
        return await LocalConversationNamingService.generateTitle(from: context)
      }
    #endif

    return nil
  }

  @discardableResult
  private func adoptMutationDetailSnapshot(
    _ payload: ServerSessionDetailSnapshotPayload?,
    fallbackSurfaces: SessionInvalidationSet
  ) -> ServerSessionDetailSnapshotPayload? {
    transport.recordRevision(payload?.revision)
    if let payload {
      lastDetailSnapshot = payload
    } else {
      transport.invalidate(fallbackSurfaces)
    }
    return payload
  }
}
