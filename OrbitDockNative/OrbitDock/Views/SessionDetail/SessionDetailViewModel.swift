import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SessionDetailViewModel {
  var copiedResume = false
  var currentSessionId = ""
  var currentEndpointId = UUID()
  var currentSessionStore = SessionStore.preview()
  var selectedWorkerId: String?
  var conversationScrollCommand: ConversationScrollCommand?
  var conversationFollowState = ConversationFollowState.initial
  var selectedSkills: Set<String> = []
  var layoutConfig: LayoutConfiguration = .conversationOnly {
    didSet {
      syncSectionPresentations()
      syncWorkerDetailPresentation()
    }
  }

  var showDiffBanner = false
  var reviewFileId: String?
  var navigateToComment: ServerReviewComment?
  var selectedCommentIds: Set<String> = []
  var pendingApprovalPanelOpenSignal = 0
  var worktreeCleanupDismissed = false
  var deleteBranchOnCleanup = true
  var isCleaningUpWorktree = false
  var worktreeCleanupError: String?

  /// Terminal panel state
  var showTerminalPanel = false
  var activeTerminalId: String?
  var showTerminalInteractiveSheet = false
  /// macOS: whether the inline terminal panel is expanded below the strip
  var showInlineTerminal = false

  @ObservationIgnored private weak var modelPricingService: ModelPricingService?
  @ObservationIgnored private var conversationScrollCommandNonce = 0
  @ObservationIgnored private var isRefreshing = false
  @ObservationIgnored private var refreshQueued = false
  @ObservationIgnored private var lastRevision: UInt64 = 0

  var screenPresentation = SessionDetailScreenPresentation.empty
  var usageSource = SessionDetailUsageSource.empty
  var worktreeState = SessionDetailWorktreeState.empty
  var reviewState = SessionDetailReviewState.empty
  var workerState = SessionDetailWorkerState.empty
  var workerRosterPresentation: SessionWorkerRosterPresentation?
  var workerDetailPresentation: SessionWorkerDetailPresentation?
  var conversationPresentation = SessionDetailConversationSectionPresentation.empty
  var reviewPresentation = SessionDetailReviewSectionPresentation.empty
  var footerMode: SessionDetailFooterMode = .passive
  var currentTool: String?
  var lastActivityAt: Date?

  func bind(
    sessionId: String,
    endpointId: UUID,
    runtimeRegistry: ServerRuntimeRegistry,
    fallbackStore: SessionStore,
    modelPricingService: ModelPricingService
  ) {
    let resolvedStore = runtimeRegistry.sessionStore(for: endpointId, fallback: fallbackStore)
    self.modelPricingService = modelPricingService

    let didSessionChange = currentSessionId != sessionId || currentEndpointId != endpointId

    currentSessionId = sessionId
    currentEndpointId = endpointId
    currentSessionStore = resolvedStore

    if didSessionChange {
      conversationFollowState = .initial
      conversationScrollCommand = nil
      conversationScrollCommandNonce = 0
      pendingApprovalPanelOpenSignal = 0
      lastRevision = 0
    }
  }

  var sessionId: String {
    currentSessionId
  }

  var endpointId: UUID {
    currentEndpointId
  }

  var sessionStore: SessionStore {
    currentSessionStore
  }

  var actionBarState: SessionDetailActionBarState {
    SessionDetailActionBarPlanner.state(
      branch: worktreeState.branch,
      projectPath: worktreeState.projectPath,
      usageStats: usageStats,
      followMode: followMode,
      unreadCount: unreadCount,
      lastActivityAt: lastActivityAt
    )
  }

  var sessionDetailWorktreeCleanupState: SessionDetailWorktreeCleanupBannerState? {
    SessionDetailWorktreeCleanupPlanner.bannerState(
      status: worktreeState.status,
      isWorktree: worktreeState.isWorktree,
      dismissed: worktreeCleanupDismissed,
      worktree: worktreeForSession,
      branch: worktreeState.branch,
      isCleaningUp: isCleaningUpWorktree
    )
  }

  var followMode: ConversationFollowMode {
    conversationFollowState.mode
  }

  var unreadCount: Int {
    conversationFollowState.unreadCount
  }

  var usageStats: TranscriptUsageStats {
    SessionDetailUsagePlanner.makeStats(
      model: usageSource.model,
      inputTokens: usageSource.inputTokens,
      outputTokens: usageSource.outputTokens,
      cachedTokens: usageSource.cachedTokens,
      contextUsed: usageSource.contextUsed,
      totalTokens: usageSource.totalTokens ?? 0,
      costCalculator: modelPricingService?.calculatorSnapshot ?? .fallback
    )
  }

  var diffFileCount: Int {
    let parsedCount = SessionDetailDiffPlanner.fileCount(
      turnDiffs: reviewState.turnDiffs,
      currentDiff: reviewState.diff,
      cumulativeDiff: reviewState.cumulativeDiff
    )
    if parsedCount > 0 {
      return parsedCount
    }
    return reviewState.turnCount > 0 ? 1 : 0
  }

  var showWorktreeCleanupBanner: Bool {
    sessionDetailWorktreeCleanupState != nil
  }

  var worktreeForSession: ServerWorktreeSummary? {
    SessionDetailWorktreeCleanupPlanner.resolveWorktree(
      worktreesByRepo: sessionStore.worktreesByRepo,
      worktreeId: worktreeState.worktreeId,
      projectPath: worktreeState.projectPath
    )
  }

  var shouldSubscribeToServerSession: Bool {
    !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func refresh() async {
    guard shouldSubscribeToServerSession else {
      apply(snapshot: .empty(endpointId: endpointId, sessionId: sessionId))
      return
    }

    if isRefreshing {
      refreshQueued = true
      return
    }

    isRefreshing = true
    refreshQueued = false
    defer {
      isRefreshing = false
      if refreshQueued {
        refreshQueued = false
        Task { await refresh() }
      }
    }

    do {
      let payload = try await sessionStore.clients.conversation.fetchSessionDetail(sessionId)
      guard payload.revision >= lastRevision else { return }
      lastRevision = payload.revision
      apply(snapshot: Self.buildSnapshot(payload: payload, endpointId: endpointId))
    } catch {
      // Non-fatal: the view keeps showing the last snapshot
    }
  }

  // MARK: - Follow State (mirrored from TimelineScrollView)

  func handleConversationFollowStateChanged(_ state: ConversationFollowState) {
    conversationFollowState = state
  }

  func jumpConversationToLatest() {
    conversationScrollCommandNonce += 1
    conversationScrollCommand = .jumpToLatest(nonce: conversationScrollCommandNonce)
  }

  func toggleConversationFollowMode() {
    conversationScrollCommandNonce += 1
    conversationScrollCommand = .toggleFollow(nonce: conversationScrollCommandNonce)
  }

  func openPendingApprovalPanel() {
    withAnimation(Motion.standard) {
      pendingApprovalPanelOpenSignal += 1
    }
    conversationScrollCommandNonce += 1
    conversationScrollCommand = .openPendingApproval(nonce: conversationScrollCommandNonce)
  }

  func navigateToReviewComment(_ comment: ServerReviewComment) {
    navigateToComment = comment
    revealReview()
  }

  func openFileInReview(projectPath: String, filePath: String) {
    let plan = SessionDetailLayoutPlanner.openFileInReviewPlan(
      projectPath: projectPath,
      currentLayout: layoutConfig,
      filePath: filePath
    )
    reviewFileId = plan.reviewFileId
    layoutConfig = plan.layoutConfig
  }

  func dismissReview() {
    layoutConfig = SessionDetailLayoutPlanner.nextLayout(
      currentLayout: layoutConfig,
      intent: .dismissReview
    )
  }

  func revealReview() {
    layoutConfig = SessionDetailLayoutPlanner.nextLayout(
      currentLayout: layoutConfig,
      intent: .revealReviewSplit
    )
    showDiffBanner = false
  }

  func revealWorkerConversationEvent(_ messageId: String) {
    if layoutConfig == .reviewOnly {
      layoutConfig = .split
    }
    conversationScrollCommandNonce += 1
    conversationScrollCommand = .revealMessage(id: messageId, nonce: conversationScrollCommandNonce)
  }

  func selectLayout(_ layout: LayoutConfiguration) {
    layoutConfig = layout
  }

  func handleDiffChange(oldDiff: String?, newDiff: String?) -> Bool {
    guard reviewState.isDirect, oldDiff == nil, newDiff != nil, layoutConfig == .conversationOnly else {
      return false
    }
    showDiffBanner = true
    return true
  }

  func handleReviewTurnCountChange(oldCount: UInt64, newCount: UInt64) -> Bool {
    guard reviewState.isDirect, newCount > oldCount, layoutConfig == .conversationOnly else {
      return false
    }
    showDiffBanner = true
    return true
  }

  func syncSelectedWorker() {
    let nextSelectedWorkerId = SessionWorkerRosterPlanner.preferredSelectedWorkerID(
      currentSelectionID: selectedWorkerId,
      subagents: workerState.subagents
    )
    if selectedWorkerId != nextSelectedWorkerId {
      selectedWorkerId = nextSelectedWorkerId
    }
    syncWorkerDetailPresentation()
  }

  func loadSelectedWorkerTools(for workerId: String? = nil) {
    guard let workerId = workerId ?? selectedWorkerId else { return }
    Task {
      let tools = try? await sessionStore.clients.sessions.getSubagentTools(sessionId: sessionId, subagentId: workerId)
      let messages = try? await sessionStore.clients.sessions.getSubagentMessages(sessionId: sessionId, subagentId: workerId)
      workerState.subagentTools[workerId] = tools ?? []
      workerState.subagentMessages[workerId] = messages ?? []
      syncWorkerDetailPresentation()
    }
  }

  func selectWorkerInPanel(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    selectedWorkerId = workerId
    syncWorkerDetailPresentation()
    loadSelectedWorkerTools(for: workerId)
  }

  func focusWorkerInDeck(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    selectWorkerInPanel(workerId)
  }

  func copyResumeCommand() {
    let command = "claude --resume \(sessionId)"
    Platform.services.copyToClipboard(command)
    copiedResume = true

    Task {
      try? await Task.sleep(for: .seconds(2))
      await MainActor.run {
        copiedResume = false
      }
    }
  }

  func endSession() {
    Task { try? await sessionStore.endSession(sessionId) }
  }

  func cleanUpWorktree() {
    guard let request = SessionDetailWorktreeCleanupPlanner.cleanupRequest(
      worktree: worktreeForSession,
      deleteBranch: deleteBranchOnCleanup
    ) else {
      return
    }

    isCleaningUpWorktree = true
    worktreeCleanupError = nil

    Task {
      do {
        try await sessionStore.clients.worktrees.removeWorktree(
          worktreeId: request.worktreeId,
          force: request.force,
          deleteBranch: request.deleteBranch
        )
        withAnimation(Motion.gentle) {
          worktreeCleanupDismissed = true
        }
      } catch {
        worktreeCleanupError = error.localizedDescription
      }
      isCleaningUpWorktree = false
    }
  }

  func sendReviewToModel() {
    guard let plan = SessionDetailReviewSendPlanner.makePlan(
      reviewComments: reviewState.reviewComments,
      selectedCommentIds: selectedCommentIds,
      turnDiffs: reviewState.turnDiffs,
      currentDiff: reviewState.diff,
      cumulativeDiff: reviewState.cumulativeDiff
    ) else {
      return
    }

    Task {
      try? await sessionStore.sendMessage(sessionId: sessionId, content: plan.message)

      for commentId in plan.commentIdsToResolve {
        try? await sessionStore.clients.approvals.updateReviewComment(
          commentId: commentId,
          body: ApprovalsClient.UpdateReviewCommentRequest(status: .resolved)
        )
      }
    }

    selectedCommentIds.removeAll()
  }

  private func apply(snapshot: SessionDetailSnapshot) {
    screenPresentation = snapshot.screenPresentation
    usageSource = snapshot.usageSource
    worktreeState = snapshot.worktreeState
    reviewState = snapshot.reviewState
    // Preserve loaded worker tools/messages across refreshes — the snapshot only carries
    // the subagent roster, not the detail payloads we fetched on-demand.
    let preservedTools = workerState.subagentTools
    let preservedMessages = workerState.subagentMessages
    workerState = SessionDetailWorkerState(
      subagents: snapshot.workerState.subagents,
      subagentTools: preservedTools,
      subagentMessages: preservedMessages,
      timelineRevision: snapshot.workerState.timelineRevision
    )
    workerRosterPresentation = SessionWorkerRosterPlanner.presentation(subagents: workerState.subagents)
    syncSelectedWorker()
    conversationPresentation = snapshot.conversationPresentation
    reviewPresentation = snapshot.reviewPresentation(layoutConfig: layoutConfig)
    footerMode = snapshot.footerMode
    currentTool = snapshot.currentTool
    lastActivityAt = snapshot.lastActivityAt
  }

  private func syncWorkerDetailPresentation() {
    guard layoutConfig != .reviewOnly, let selectedWorkerId else {
      workerDetailPresentation = nil
      return
    }

    let hasLoadedWorkerPayload =
      workerState.subagentTools[selectedWorkerId] != nil || workerState.subagentMessages[selectedWorkerId] != nil

    guard hasLoadedWorkerPayload else {
      workerDetailPresentation = nil
      return
    }

    workerDetailPresentation = SessionWorkerRosterPlanner.detailPresentation(
      subagents: workerState.subagents,
      selectedWorkerID: selectedWorkerId,
      toolsByWorker: workerState.subagentTools,
      messagesByWorker: workerState.subagentMessages,
      timelineEntries: []
    )
  }

  private func syncSectionPresentations() {
    conversationPresentation = SessionDetailConversationSectionPresentation(
      sessionId: sessionId,
      endpointId: endpointId,
      isSessionActive: screenPresentation.isActive,
      displayStatus: screenPresentation.displayStatus,
      currentTool: currentTool,
      projectPath: screenPresentation.projectPath,
      canOpenFileInReview: screenPresentation.isDirect
    )
    reviewPresentation = SessionDetailReviewSectionPresentation(
      sessionId: sessionId,
      projectPath: screenPresentation.projectPath,
      isSessionActive: screenPresentation.isActive,
      compact: layoutConfig == .split
    )
  }

  private static func buildSnapshot(
    payload: ServerSessionDetailSnapshotPayload,
    endpointId: UUID
  ) -> SessionDetailSnapshot {
    let s = payload.session
    let sessionId = s.id
    let isDirect = s.controlMode == .direct
    let isActive = s.lifecycleState != .ended
    let provider: Provider = s.provider == .codex ? .codex : .claude
    let displayName = resolveDisplayName(s)
    let displayStatus = resolveDisplayStatus(s, isActive: isActive)
    let workStatus = s.workStatus.toSessionWorkStatus()
    let hasGitRepository = s.gitBranch != nil || s.currentCwd != nil || s.isWorktree

    return SessionDetailSnapshot(
      screenPresentation: SessionDetailScreenPresentation(
        displayName: displayName,
        isDirect: isDirect,
        isActive: isActive,
        displayStatus: displayStatus,
        workStatus: workStatus,
        provider: provider,
        model: s.model,
        effort: s.effort,
        endpointName: nil,
        projectPath: s.projectPath,
        issueIdentifier: s.issueIdentifier,
        missionId: s.missionId,
        capabilities: isDirect ? [.direct] : (provider == .codex ? [.passive] : []),
        continuation: SessionContinuation(
          endpointId: endpointId,
          sessionId: sessionId,
          provider: provider,
          displayName: displayName,
          projectPath: s.projectPath,
          model: s.model,
          hasGitRepository: hasGitRepository
        ),
        debugContext: SessionDetailDebugContext(
          sessionId: sessionId,
          threadId: nil,
          projectPath: s.projectPath,
          provider: provider,
          codexIntegrationMode: s.codexIntegrationMode.map { String(describing: $0) },
          claudeIntegrationMode: s.claudeIntegrationMode.map { String(describing: $0) }
        )
      ),
      usageSource: SessionDetailUsageSource(
        model: s.model,
        inputTokens: Int(s.tokenUsage.inputTokens),
        outputTokens: Int(s.tokenUsage.outputTokens),
        cachedTokens: Int(s.tokenUsage.cachedTokens),
        contextUsed: Int(s.tokenUsage.contextWindow),
        totalTokens: Int(s.tokenUsage.inputTokens + s.tokenUsage.outputTokens)
      ),
      worktreeState: SessionDetailWorktreeState(
        status: mapSessionStatus(s.status),
        isWorktree: s.isWorktree,
        branch: s.gitBranch,
        worktreeId: s.worktreeId,
        projectPath: s.projectPath
      ),
      reviewState: SessionDetailReviewState(
        diff: s.currentDiff,
        cumulativeDiff: s.cumulativeDiff,
        turnDiffs: s.turnDiffs,
        reviewComments: [],
        isDirect: isDirect,
        turnCount: s.turnCount
      ),
      workerState: SessionDetailWorkerState(
        subagents: s.subagents,
        subagentTools: [:],
        subagentMessages: [:],
        timelineRevision: 0
      ),
      currentTool: s.pendingToolName,
      lastActivityAt: parseServerTimestamp(s.lastActivityAt),
      footerMode: SessionDetailFooterPlanner.mode(
        controlMode: isDirect ? .direct : .passive,
        lifecycleState: s.lifecycleState
      ),
      sessionStoreEndpointId: endpointId,
      sessionId: sessionId
    )
  }

  private static func resolveDisplayName(_ s: ServerSessionState) -> String {
    SessionSemantics.displayName(
      customName: s.customName,
      summary: s.summary,
      firstPrompt: s.firstPrompt,
      projectName: s.projectName,
      projectPath: s.projectPath
    )
  }

  private static func resolveDisplayStatus(_ s: ServerSessionState, isActive: Bool) -> SessionDisplayStatus {
    guard isActive else { return .ended }
    if s.pendingApproval != nil {
      switch s.pendingApproval?.type {
        case .permissions: return .permission
        case .question: return .question
        default: return .permission
      }
    }
    switch s.workStatus {
      case .working: return .working
      case .permission: return .permission
      case .question: return .question
      case .waiting, .reply, .ended: return .reply
    }
  }

  private static func mapSessionStatus(_ status: ServerSessionStatus) -> Session.SessionStatus {
    switch status {
      case .active: .active
      case .ended: .ended
    }
  }
}

struct SessionDetailSnapshot {
  let screenPresentation: SessionDetailScreenPresentation
  let usageSource: SessionDetailUsageSource
  let worktreeState: SessionDetailWorktreeState
  let reviewState: SessionDetailReviewState
  let workerState: SessionDetailWorkerState
  let currentTool: String?
  let lastActivityAt: Date?
  let footerMode: SessionDetailFooterMode
  let sessionStoreEndpointId: UUID
  let sessionId: String

  func reviewPresentation(layoutConfig: LayoutConfiguration) -> SessionDetailReviewSectionPresentation {
    SessionDetailReviewSectionPresentation(
      sessionId: sessionId,
      projectPath: screenPresentation.projectPath,
      isSessionActive: screenPresentation.isActive,
      compact: layoutConfig == .split
    )
  }

  var conversationPresentation: SessionDetailConversationSectionPresentation {
    SessionDetailConversationSectionPresentation(
      sessionId: sessionId,
      endpointId: sessionStoreEndpointId,
      isSessionActive: screenPresentation.isActive,
      displayStatus: screenPresentation.displayStatus,
      currentTool: currentTool,
      projectPath: screenPresentation.projectPath,
      canOpenFileInReview: screenPresentation.isDirect
    )
  }

  static func empty(endpointId: UUID, sessionId: String) -> SessionDetailSnapshot {
    SessionDetailSnapshot(
      screenPresentation: .empty,
      usageSource: .empty,
      worktreeState: .empty,
      reviewState: .empty,
      workerState: .empty,
      currentTool: nil,
      lastActivityAt: nil,
      footerMode: .passive,
      sessionStoreEndpointId: endpointId,
      sessionId: sessionId
    )
  }
}

struct SessionDetailScreenPresentation {
  let displayName: String
  let isDirect: Bool
  let isActive: Bool
  let displayStatus: SessionDisplayStatus
  let workStatus: Session.WorkStatus
  let provider: Provider
  let model: String?
  let effort: String?
  let endpointName: String?
  let projectPath: String
  let issueIdentifier: String?
  let missionId: String?
  let capabilities: [SessionCapability]
  let continuation: SessionContinuation
  let debugContext: SessionDetailDebugContext

  static let empty = SessionDetailScreenPresentation(
    displayName: "Session",
    isDirect: false,
    isActive: false,
    displayStatus: .ended,
    workStatus: .unknown,
    provider: .claude,
    model: nil,
    effort: nil,
    endpointName: nil,
    projectPath: "",
    issueIdentifier: nil,
    missionId: nil,
    capabilities: [],
    continuation: SessionContinuation(
      endpointId: UUID(),
      sessionId: "",
      provider: .claude,
      displayName: "Session",
      projectPath: "",
      model: nil,
      hasGitRepository: false
    ),
    debugContext: .empty
  )
}

struct SessionDetailDebugContext {
  let sessionId: String
  let threadId: String?
  let projectPath: String
  let provider: Provider
  let codexIntegrationMode: String?
  let claudeIntegrationMode: String?

  static let empty = SessionDetailDebugContext(
    sessionId: "",
    threadId: nil,
    projectPath: "",
    provider: .claude,
    codexIntegrationMode: nil,
    claudeIntegrationMode: nil
  )
}

struct SessionDetailConversationSectionPresentation {
  let sessionId: String
  let endpointId: UUID
  let isSessionActive: Bool
  let displayStatus: SessionDisplayStatus
  let currentTool: String?
  let projectPath: String
  let canOpenFileInReview: Bool

  static let empty = SessionDetailConversationSectionPresentation(
    sessionId: "",
    endpointId: UUID(),
    isSessionActive: false,
    displayStatus: .ended,
    currentTool: nil,
    projectPath: "",
    canOpenFileInReview: false
  )
}

struct SessionDetailReviewSectionPresentation {
  let sessionId: String
  let projectPath: String
  let isSessionActive: Bool
  let compact: Bool

  static let empty = SessionDetailReviewSectionPresentation(
    sessionId: "",
    projectPath: "",
    isSessionActive: false,
    compact: false
  )
}

struct SessionDetailUsageSource {
  let model: String?
  let inputTokens: Int?
  let outputTokens: Int?
  let cachedTokens: Int?
  let contextUsed: Int
  let totalTokens: Int?

  static let empty = SessionDetailUsageSource(
    model: nil,
    inputTokens: nil,
    outputTokens: nil,
    cachedTokens: nil,
    contextUsed: 0,
    totalTokens: nil
  )
}

struct SessionDetailWorktreeState {
  let status: Session.SessionStatus
  let isWorktree: Bool
  let branch: String?
  let worktreeId: String?
  let projectPath: String

  static let empty = SessionDetailWorktreeState(
    status: .active,
    isWorktree: false,
    branch: nil,
    worktreeId: nil,
    projectPath: ""
  )
}

struct SessionDetailReviewState {
  let diff: String?
  let cumulativeDiff: String?
  let turnDiffs: [ServerTurnDiff]
  let reviewComments: [ServerReviewComment]
  let isDirect: Bool
  let turnCount: UInt64

  static let empty = SessionDetailReviewState(
    diff: nil,
    cumulativeDiff: nil,
    turnDiffs: [],
    reviewComments: [],
    isDirect: false,
    turnCount: 0
  )
}

struct SessionDetailWorkerState {
  let subagents: [ServerSubagentInfo]
  var subagentTools: [String: [ServerSubagentTool]]
  var subagentMessages: [String: [ServerConversationRowEntry]]
  let timelineRevision: Int

  static let empty = SessionDetailWorkerState(
    subagents: [],
    subagentTools: [:],
    subagentMessages: [:],
    timelineRevision: 0
  )
}
