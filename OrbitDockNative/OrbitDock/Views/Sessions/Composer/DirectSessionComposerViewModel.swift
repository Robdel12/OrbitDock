import Observation
import SwiftUI

@MainActor
@Observable
final class DirectSessionComposerViewModel {
  var currentSessionId: String?
  var currentSessionStore = SessionStore.preview()
  var sessionState = DirectSessionComposerSessionState.empty

  @ObservationIgnored private var sessionObservationGeneration: UInt64 = 0

  func bind(sessionId: String, sessionStore: SessionStore) {
    currentSessionId = sessionId
    currentSessionStore = sessionStore
    sessionObservationGeneration &+= 1
    startObservation(generation: sessionObservationGeneration)
  }

  private var resolvedSessionId: String {
    currentSessionId ?? ""
  }

  var endpointId: UUID {
    currentSessionStore.endpointId
  }

  var isRemoteConnection: Bool {
    currentSessionStore.isRemoteConnection
  }

  var codexModels: [ServerCodexModelOption] {
    currentSessionStore.codexModels
  }

  var claudeModels: [ServerClaudeModelOption] {
    ServerClaudeModelOption.defaults
  }

  var projectFileIndex: ProjectFileIndex {
    currentSessionStore.projectFileIndex
  }

  var imageLoader: ImageLoader {
    currentSessionStore.clients.imageLoader
  }

  var enabledSkills: [ServerSkillMetadata] {
    sessionState.skills.filter(\.enabled)
  }

  var permissionPanelState: PermissionInlinePanelState {
    PermissionInlinePanelState(
      autonomy: sessionState.autonomy,
      autonomyConfiguredOnServer: sessionState.autonomyConfiguredOnServer,
      permissionMode: sessionState.permissionMode,
      allowBypassPermissions: sessionState.allowBypassPermissions,
      isDirectCodex: sessionState.isDirectCodex,
      isDirectClaude: sessionState.isDirectClaude,
      permissionRules: sessionState.permissionRules,
      permissionRulesLoading: sessionState.permissionRulesLoading,
      approvalHistory: sessionState.approvalHistory
    )
  }

  var hasClaudeSkills: Bool {
    sessionState.hasClaudeSkills
  }

  var hasMcpData: Bool {
    sessionState.hasMcpData
  }

  var mcpTools: [String: ServerMcpTool] {
    sessionState.mcpTools
  }

  var mcpResources: [String: [ServerMcpResource]] {
    sessionState.mcpResources
  }

  var mcpResourceTemplates: [String: [ServerMcpResourceTemplate]] {
    sessionState.mcpResourceTemplates
  }

  func worktrees(for repoPath: String) -> [ServerWorktreeSummary] {
    currentSessionStore.worktrees(for: repoPath)
  }

  func refreshCodexModels() {
    currentSessionStore.refreshCodexModels()
  }

  func loadPermissionRules() async throws {
    _ = try await currentSessionStore.loadPermissionRules(sessionId: resolvedSessionId)
  }

  func removePermissionRule(pattern: String, behavior: String) async throws {
    try await currentSessionStore.removePermissionRule(
      sessionId: resolvedSessionId,
      pattern: pattern,
      behavior: behavior,
      scope: "session"
    )
  }

  func updateAutonomy(_ level: AutonomyLevel) async throws {
    try await currentSessionStore.updateSessionConfig(
      resolvedSessionId,
      approvalPolicy: level.approvalPolicy,
      approvalPolicyDetails: level.approvalPolicyDetails,
      sandboxMode: level.sandboxMode
    )
  }

  func updateCodexApprovalPolicy(
    details: ServerCodexApprovalPolicy,
    sandboxMode: String?
  ) async throws {
    try await currentSessionStore.updateSessionConfig(
      resolvedSessionId,
      approvalPolicy: details.legacySummary == "granular" ? nil : details.legacySummary,
      approvalPolicyDetails: details,
      sandboxMode: sandboxMode
    )
  }

  func updateClaudePermissionMode(_ mode: ClaudePermissionMode) async throws {
    try await currentSessionStore.updateClaudePermissionMode(resolvedSessionId, mode: mode)
  }

  func updateCodexCollaborationMode(_ mode: CodexCollaborationMode) async throws {
    try await currentSessionStore.updateSessionConfig(resolvedSessionId, collaborationMode: mode.rawValue)
  }

  func listSkills() async throws {
    try await currentSessionStore.listSkills(sessionId: resolvedSessionId)
  }

  func listMcpTools() async throws {
    try await currentSessionStore.listMcpTools(sessionId: resolvedSessionId)
  }

  func refreshMcpServers() async throws {
    try await currentSessionStore.refreshMcpServers(resolvedSessionId)
  }

  func executeShell(command: String) async throws {
    try await currentSessionStore.executeShell(resolvedSessionId, command: command)
  }

  func uploadImageAttachment(
    data: Data,
    mimeType: String,
    displayName: String,
    pixelWidth: Int,
    pixelHeight: Int
  ) async throws -> ServerImageInput {
    try await currentSessionStore.uploadImageAttachment(
      sessionId: resolvedSessionId,
      data: data,
      mimeType: mimeType,
      displayName: displayName,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
  }

  func sendMessage(_ request: ConversationClient.SendMessageRequest) async throws {
    try await currentSessionStore.sendMessage(
      sessionId: resolvedSessionId,
      content: request.content,
      model: request.model,
      effort: request.effort,
      skills: request.skills,
      images: request.images,
      mentions: request.mentions
    )
  }

  func sendMessage(content: String) async throws {
    try await currentSessionStore.sendMessage(sessionId: resolvedSessionId, content: content)
  }

  func steerTurn(_ request: ConversationClient.SteerTurnRequest) async throws {
    try await currentSessionStore.steerTurn(
      sessionId: resolvedSessionId,
      content: request.content,
      images: request.images,
      mentions: request.mentions
    )
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
  ) async throws {
    try await currentSessionStore.updateCodexSessionOverrides(
      resolvedSessionId,
      configMode: configMode,
      configProfile: configProfile,
      modelProvider: modelProvider,
      collaborationMode: collaborationMode,
      multiAgent: multiAgent,
      personality: personality,
      serviceTier: serviceTier,
      developerInstructions: developerInstructions
    )
  }

  func inspectCodexConfig(
    _ request: SessionsClient.CodexInspectRequest
  ) async throws -> SessionsClient.CodexInspectorResponse {
    try await currentSessionStore.clients.sessions.inspectCodexConfig(request)
  }

  func fetchCodexConfigCatalog(cwd: String) async throws -> SessionsClient.CodexConfigCatalogResponse {
    try await currentSessionStore.clients.sessions.fetchCodexConfigCatalog(cwd: cwd)
  }

  func fetchCodexConfigDocuments(cwd: String) async throws -> SessionsClient.CodexConfigDocumentsResponse {
    try await currentSessionStore.clients.sessions.fetchCodexConfigDocuments(cwd: cwd)
  }

  func batchWriteCodexConfig(
    _ request: SessionsClient.CodexConfigBatchWriteRequest
  ) async throws -> SessionsClient.CodexConfigWriteResponseData {
    try await currentSessionStore.clients.sessions.batchWriteCodexConfig(request)
  }

  func refreshWorktreesForActiveSessions() {
    currentSessionStore.refreshWorktreesForActiveSessions()
  }

  func forkSessionToWorktree(
    branchName: String,
    baseBranch: String?,
    nthUserMessage: Int? = nil
  ) async throws {
    try await currentSessionStore.forkSessionToWorktree(
      sessionId: resolvedSessionId,
      branchName: branchName,
      baseBranch: baseBranch,
      nthUserMessage: nthUserMessage.map(UInt32.init)
    )
  }

  func forkSessionToExistingWorktree(
    worktreeId: String,
    nthUserMessage: Int? = nil
  ) async throws {
    try await currentSessionStore.forkSessionToExistingWorktree(
      sessionId: resolvedSessionId,
      worktreeId: worktreeId,
      nthUserMessage: nthUserMessage.map(UInt32.init)
    )
  }

  func undoLastTurn() async throws {
    try await currentSessionStore.undoLastTurn(resolvedSessionId)
  }

  func rewindFiles(userMessageId: String) async throws {
    try await currentSessionStore.rewindFiles(resolvedSessionId, userMessageId: userMessageId)
  }

  func forkSession(nthUserMessage: Int? = nil) async throws {
    try await currentSessionStore.forkSession(
      sessionId: resolvedSessionId,
      nthUserMessage: nthUserMessage.map(UInt32.init)
    )
  }

  func compactContext() async throws {
    try await currentSessionStore.compactContext(resolvedSessionId)
  }

  func rollbackTurns(numTurns: UInt32) async throws {
    try await currentSessionStore.rollbackTurns(resolvedSessionId, numTurns: numTurns)
  }

  func resumeSession() async throws {
    try await currentSessionStore.resumeSession(resolvedSessionId)
  }

  func interruptSession() async throws {
    try await currentSessionStore.interruptSession(resolvedSessionId)
  }

  func takeoverSession(_ sessionId: String? = nil) async throws {
    try await currentSessionStore.takeoverSession(sessionId ?? resolvedSessionId)
  }

  func answerQuestion(
    sessionId: String? = nil,
    requestId: String,
    answer: String,
    questionId: String? = nil,
    answers: [String: [String]] = [:]
  ) async throws {
    try await currentSessionStore.answerQuestion(
      sessionId: sessionId ?? resolvedSessionId,
      requestId: requestId,
      answer: answer,
      questionId: questionId,
      answers: answers
    )
  }

  func approveTool(
    sessionId: String? = nil,
    requestId: String,
    decision: ApprovalsClient.ToolApprovalDecision,
    message: String? = nil,
    interrupt: Bool? = nil
  ) async throws {
    try await currentSessionStore.approveTool(
      sessionId: sessionId ?? resolvedSessionId,
      requestId: requestId,
      decision: decision,
      message: message,
      interrupt: interrupt
    )
  }

  func respondToPermissionRequest(
    sessionId: String? = nil,
    requestId: String,
    scope: ServerPermissionGrantScope,
    grantRequestedPermissions: Bool
  ) async throws {
    try await currentSessionStore.respondToPermissionRequest(
      sessionId: sessionId ?? resolvedSessionId,
      requestId: requestId,
      scope: scope,
      grantRequestedPermissions: grantRequestedPermissions
    )
  }

  func hasSlashCommand(_ name: String) -> Bool {
    sessionState.slashCommands.contains(name)
  }

  var undoInProgress: Bool {
    sessionState.undoInProgress
  }

  var compactInProgress: Bool {
    sessionState.compactInProgress
  }

  var rollbackInProgress: Bool {
    sessionState.rollbackInProgress
  }

  func consumeShellContext() -> String? {
    guard let currentSessionId else { return nil }
    return currentSessionStore.session(currentSessionId).consumeShellContext()
  }

  private func startObservation(generation: UInt64) {
    guard let currentSessionId else {
      sessionState = .empty
      return
    }

    let sessionStore = currentSessionStore

    withObservationTracking {
      sessionState = Self.makeSessionState(from: sessionStore.session(currentSessionId))
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.sessionObservationGeneration == generation else { return }
        self.startObservation(generation: generation)
      }
    }
  }

  private static func makeSessionState(from session: SessionObservable) -> DirectSessionComposerSessionState {
    DirectSessionComposerSessionState(
      provider: session.provider,
      displayName: session.displayName,
      projectPath: session.projectPath,
      projectName: session.projectName,
      model: session.model,
      effort: session.effort,
      branch: session.branch,
      repositoryRoot: session.repositoryRoot,
      isWorktree: session.isWorktree,
      steerable: session.steerable,
      workStatus: session.workStatus,
      isActive: session.isActive,
      isDirectCodex: session.isDirectCodex,
      isDirectClaude: session.isDirectClaude,
      approvalCardContext: session.approvalCardContext,
      pendingApproval: session.pendingApproval,
      approvalHistory: session.approvalHistory,
      permissionRules: session.permissionRules,
      permissionRulesLoading: session.permissionRulesLoading,
      rowEntries: session.rowEntries,
      rowEntriesRevision: session.rowEntriesRevision,
      promptSuggestions: session.promptSuggestions,
      rateLimitInfo: session.rateLimitInfo,
      autonomy: session.autonomy,
      autonomyConfiguredOnServer: session.autonomyConfiguredOnServer,
      permissionMode: session.permissionMode,
      allowBypassPermissions: session.allowBypassPermissions,
      collaborationMode: session.collaborationMode,
      multiAgent: session.multiAgent,
      personality: session.personality,
      serviceTier: session.serviceTier,
      developerInstructions: session.developerInstructions,
      codexConfigSource: session.codexConfigSource,
      codexConfigMode: session.codexConfigMode,
      codexConfigProfile: session.codexConfigProfile,
      codexModelProvider: session.codexModelProvider,
      codexConfigOverrides: session.codexConfigOverrides,
      skills: session.skills,
      slashCommands: session.slashCommands,
      claudeSkillNames: session.claudeSkillNames,
      mcpTools: session.mcpTools,
      mcpResources: session.mcpResources,
      mcpResourceTemplates: session.mcpResourceTemplates,
      inputTokens: session.inputTokens,
      outputTokens: session.outputTokens,
      cachedTokens: session.cachedTokens,
      contextWindow: session.contextWindow,
      tokenUsageSnapshotKind: session.tokenUsageSnapshotKind,
      forkInProgress: session.forkInProgress,
      lastFilesPersistedAt: session.lastFilesPersistedAt,
      lastActivityAt: session.lastActivityAt,
      undoInProgress: session.undoInProgress,
      compactInProgress: session.compactInProgress,
      rollbackInProgress: session.rollbackInProgress,
      turnCount: session.turnCount
    )
  }
}

struct DirectSessionComposerSessionState {
  let provider: Provider
  let displayName: String
  let projectPath: String
  let projectName: String?
  let model: String?
  let effort: String?
  let branch: String?
  let repositoryRoot: String?
  let isWorktree: Bool
  let steerable: Bool
  let workStatus: Session.WorkStatus
  let isActive: Bool
  let isDirectCodex: Bool
  let isDirectClaude: Bool
  let approvalCardContext: ApprovalCardSessionContext
  let pendingApproval: ServerApprovalRequest?
  let approvalHistory: [ServerApprovalHistoryItem]
  let permissionRules: ServerSessionPermissionRules?
  let permissionRulesLoading: Bool
  let rowEntries: [ServerConversationRowEntry]
  let rowEntriesRevision: Int
  let promptSuggestions: [String]
  let rateLimitInfo: ServerRateLimitInfo?
  let autonomy: AutonomyLevel
  let autonomyConfiguredOnServer: Bool
  let permissionMode: ClaudePermissionMode
  let allowBypassPermissions: Bool
  let collaborationMode: String?
  let multiAgent: Bool?
  let personality: String?
  let serviceTier: String?
  let developerInstructions: String?
  let codexConfigSource: ServerCodexConfigSource?
  let codexConfigMode: ServerCodexConfigMode?
  let codexConfigProfile: String?
  let codexModelProvider: String?
  let codexConfigOverrides: ServerCodexSessionOverrides?
  let skills: [ServerSkillMetadata]
  let slashCommands: Set<String>
  let claudeSkillNames: [String]
  let mcpTools: [String: ServerMcpTool]
  let mcpResources: [String: [ServerMcpResource]]
  let mcpResourceTemplates: [String: [ServerMcpResourceTemplate]]
  let inputTokens: Int?
  let outputTokens: Int?
  let cachedTokens: Int?
  let contextWindow: Int?
  let tokenUsageSnapshotKind: ServerTokenUsageSnapshotKind
  let forkInProgress: Bool
  let lastFilesPersistedAt: Date?
  let lastActivityAt: Date?
  let undoInProgress: Bool
  let compactInProgress: Bool
  let rollbackInProgress: Bool
  let turnCount: UInt64

  var hasClaudeSkills: Bool {
    !claudeSkillNames.isEmpty
  }

  var isDirect: Bool {
    isDirectCodex || isDirectClaude
  }

  var hasMcpData: Bool {
    !mcpTools.isEmpty || !mcpResources.isEmpty || !mcpResourceTemplates.isEmpty
  }

  var effectiveContextInputTokens: Int {
    SessionTokenUsageSemantics.effectiveContextInputTokens(
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      snapshotKind: tokenUsageSnapshotKind,
      provider: provider
    )
  }

  var contextFillFraction: Double {
    SessionTokenUsageSemantics.contextFillFraction(
      contextWindow: contextWindow,
      effectiveContextInputTokens: effectiveContextInputTokens
    )
  }

  var effectiveCacheHitPercent: Double {
    SessionTokenUsageSemantics.effectiveCacheHitPercent(
      inputTokens: inputTokens,
      cachedTokens: cachedTokens,
      snapshotKind: tokenUsageSnapshotKind,
      effectiveContextInputTokens: effectiveContextInputTokens
    )
  }

  var hasTokenUsage: Bool {
    SessionTokenUsageSemantics.hasTokenUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens
    )
  }

  static let empty = DirectSessionComposerSessionState(
    provider: .claude,
    displayName: "Session",
    projectPath: "",
    projectName: nil,
    model: nil,
    effort: nil,
    branch: nil,
    repositoryRoot: nil,
    isWorktree: false,
    steerable: false,
    workStatus: .unknown,
    isActive: false,
    isDirectCodex: false,
    isDirectClaude: false,
    approvalCardContext: ApprovalCardSessionContext(
      id: "",
      projectPath: "",
      isActive: false,
      attentionReason: .none,
      pendingApprovalId: nil,
      pendingToolName: nil,
      pendingToolInput: nil,
      canApprove: false,
      canAnswer: false,
      canTakeOver: false,
      canSendInput: false
    ),
    pendingApproval: nil,
    approvalHistory: [],
    permissionRules: nil,
    permissionRulesLoading: false,
    rowEntries: [],
    rowEntriesRevision: 0,
    promptSuggestions: [],
    rateLimitInfo: nil,
    autonomy: .autonomous,
    autonomyConfiguredOnServer: true,
    permissionMode: .default,
    allowBypassPermissions: false,
    collaborationMode: nil,
    multiAgent: nil,
    personality: nil,
    serviceTier: nil,
    developerInstructions: nil,
    codexConfigSource: nil,
    codexConfigMode: nil,
    codexConfigProfile: nil,
    codexModelProvider: nil,
    codexConfigOverrides: nil,
    skills: [],
    slashCommands: [],
    claudeSkillNames: [],
    mcpTools: [:],
    mcpResources: [:],
    mcpResourceTemplates: [:],
    inputTokens: nil,
    outputTokens: nil,
    cachedTokens: nil,
    contextWindow: nil,
    tokenUsageSnapshotKind: .unknown,
    forkInProgress: false,
    lastFilesPersistedAt: nil,
    lastActivityAt: nil,
    undoInProgress: false,
    compactInProgress: false,
    rollbackInProgress: false,
    turnCount: 0
  )
}
