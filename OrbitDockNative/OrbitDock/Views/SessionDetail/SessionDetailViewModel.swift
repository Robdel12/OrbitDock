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
  var conversationJumpTarget: ConversationJumpTarget?
  var isPinned = true
  var unreadCount = 0
  var scrollToBottomTrigger = 0
  var selectedSkills: Set<String> = []
  var layoutConfig: LayoutConfiguration = .conversationOnly {
    didSet {
      syncSectionPresentations()
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

  @ObservationIgnored private weak var modelPricingService: ModelPricingService?
  @ObservationIgnored private var sessionObservationGeneration: UInt64 = 0

  var screenPresentation = SessionDetailScreenPresentation.empty
  var usageSource = SessionDetailUsageSource.empty
  var worktreeState = SessionDetailWorktreeState.empty
  var reviewState = SessionDetailReviewState.empty
  var workerState = SessionDetailWorkerState.empty
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

    guard currentSessionId != sessionId || currentEndpointId != endpointId || currentSessionStore
      .endpointId != resolvedStore.endpointId
    else {
      self.modelPricingService = modelPricingService
      currentSessionStore = resolvedStore
      refreshFromSession()
      return
    }

    currentSessionId = sessionId
    currentEndpointId = endpointId
    currentSessionStore = resolvedStore
    self.modelPricingService = modelPricingService
    sessionObservationGeneration &+= 1
    startSessionObservation(generation: sessionObservationGeneration)
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
      isPinned: isPinned,
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

  var conversationChromeState: SessionDetailConversationChromeState {
    SessionDetailConversationChromeState(
      isPinned: isPinned,
      unreadCount: unreadCount,
      scrollToBottomTrigger: scrollToBottomTrigger,
      pendingApprovalPanelOpenSignal: pendingApprovalPanelOpenSignal
    )
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

  var workerRosterPresentation: SessionWorkerRosterPresentation? {
    SessionWorkerRosterPlanner.presentation(subagents: workerState.subagents)
  }

  var workerDetailPresentation: SessionWorkerDetailPresentation? {
    guard layoutConfig != .reviewOnly, let selectedWorkerId else { return nil }

    let hasLoadedWorkerPayload =
      workerState.subagentTools[selectedWorkerId] != nil || workerState.subagentMessages[selectedWorkerId] != nil

    guard hasLoadedWorkerPayload else { return nil }

    return SessionWorkerRosterPlanner.detailPresentation(
      subagents: workerState.subagents,
      selectedWorkerID: selectedWorkerId,
      toolsByWorker: workerState.subagentTools,
      messagesByWorker: workerState.subagentMessages,
      timelineEntries: workerState.timelineEntries
    )
  }

  var workerSelectionSignature: [String] {
    workerState.subagents.map {
      [
        $0.id,
        $0.status?.rawValue ?? "none",
        $0.lastActivityAt ?? "",
      ].joined(separator: "|")
    }
  }

  var diffFileCount: Int {
    SessionDetailDiffPlanner.fileCount(
      turnDiffs: reviewState.turnDiffs,
      currentDiff: reviewState.diff,
      cumulativeDiff: reviewState.cumulativeDiff
    )
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

  func refreshFromSession() {
    guard shouldSubscribeToServerSession else {
      apply(snapshot: .empty(endpointId: endpointId, sessionId: sessionId))
      return
    }

    let snapshot = makeSnapshot(
      session: sessionStore.session(sessionId),
      endpointId: endpointId,
      sessionId: sessionId
    )
    apply(snapshot: snapshot)
  }

  func applyConversationChromeState(
    _ state: SessionDetailConversationChromeState,
    animatePendingApprovalPanel: Bool = false
  ) {
    if animatePendingApprovalPanel {
      withAnimation(Motion.standard) {
        pendingApprovalPanelOpenSignal = state.pendingApprovalPanelOpenSignal
      }
    } else {
      pendingApprovalPanelOpenSignal = state.pendingApprovalPanelOpenSignal
    }

    isPinned = state.isPinned
    unreadCount = state.unreadCount
    scrollToBottomTrigger = state.scrollToBottomTrigger
  }

  func handlePinnedChange(_ pinned: Bool) {
    guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if pinned { unreadCount = 0 }
  }

  func handleConversationTimelineReachedBottom() {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.timelineReachedBottom(current: conversationChromeState)
    )
  }

  func handleConversationTimelineLeftBottomByUser() {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.timelineLeftBottomByUser(current: conversationChromeState)
    )
  }

  func handleConversationEntryCountChange(oldCount: Int, newCount: Int) {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.didReceiveEntries(
        current: conversationChromeState,
        oldCount: oldCount,
        newCount: newCount
      )
    )
  }

  func handleComposerHeightChanged() {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.composerHeightChanged(current: conversationChromeState)
    )
  }

  func jumpConversationToLatest() {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.jumpToLatest(current: conversationChromeState)
    )
  }

  func toggleConversationPinnedState() {
    applyConversationChromeState(
      SessionDetailConversationChromePlanner.togglePinned(current: conversationChromeState)
    )
  }

  func openPendingApprovalPanel() {
    let nextState = SessionDetailConversationChromePlanner.openPendingApprovalPanel(
      current: conversationChromeState
    )
    applyConversationChromeState(nextState, animatePendingApprovalPanel: true)
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
    isPinned = false
    conversationJumpTarget = .init(
      messageID: messageId,
      nonce: (conversationJumpTarget?.nonce ?? 0) + 1
    )
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

  func syncSelectedWorker() {
    selectedWorkerId = SessionWorkerRosterPlanner.preferredSelectedWorkerID(
      currentSelectionID: selectedWorkerId,
      subagents: workerState.subagents
    )
  }

  func loadSelectedWorkerTools(for workerId: String? = nil) {
    guard let workerId = workerId ?? selectedWorkerId else { return }
    sessionStore.getSubagentTools(sessionId: sessionId, subagentId: workerId)
    sessionStore.getSubagentMessages(sessionId: sessionId, subagentId: workerId)
  }

  func selectWorkerInPanel(_ workerId: String) {
    guard !workerId.isEmpty else { return }
    selectedWorkerId = workerId
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

  func endDirectSession() {
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

  private func startSessionObservation(generation: UInt64) {
    guard shouldSubscribeToServerSession else {
      apply(snapshot: .empty(endpointId: endpointId, sessionId: sessionId))
      return
    }

    let sessionId = self.sessionId
    let endpointId = self.endpointId
    let sessionStore = self.sessionStore

    withObservationTracking {
      let snapshot = makeSnapshot(
        session: sessionStore.session(sessionId),
        endpointId: endpointId,
        sessionId: sessionId
      )
      apply(snapshot: snapshot)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.sessionObservationGeneration == generation else { return }
        self.startSessionObservation(generation: generation)
      }
    }
  }

  private func apply(snapshot: SessionDetailSnapshot) {
    screenPresentation = snapshot.screenPresentation
    usageSource = snapshot.usageSource
    worktreeState = snapshot.worktreeState
    reviewState = snapshot.reviewState
    workerState = snapshot.workerState
    conversationPresentation = snapshot.conversationPresentation
    reviewPresentation = snapshot.reviewPresentation(layoutConfig: layoutConfig)
    footerMode = snapshot.footerMode
    currentTool = snapshot.currentTool
    lastActivityAt = snapshot.lastActivityAt
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

  private func makeSnapshot(
    session: SessionObservable,
    endpointId: UUID,
    sessionId: String
  ) -> SessionDetailSnapshot {
    SessionDetailSnapshot(
      screenPresentation: SessionDetailScreenPresentation(
        displayName: session.displayName,
        isDirect: session.isDirect,
        isActive: session.isActive,
        displayStatus: session.displayStatus,
        workStatus: session.workStatus,
        provider: session.provider,
        model: session.model,
        effort: session.effort,
        endpointName: session.endpointName,
        projectPath: session.projectPath,
        issueIdentifier: session.issueIdentifier,
        missionId: session.missionId,
        capabilities: session.isDirect ? [.direct] : (session.provider == .codex ? [.passive] : []),
        continuation: SessionContinuation(
          endpointId: endpointId,
          sessionId: sessionId,
          provider: session.provider,
          displayName: session.displayName,
          projectPath: session.projectPath,
          model: session.model,
          hasGitRepository: session.branch != nil || session.repositoryRoot != nil || session.isWorktree
        ),
        debugContext: SessionDetailDebugContext(
          sessionId: sessionId,
          threadId: session.codexThreadId,
          projectPath: session.projectPath,
          provider: session.provider,
          codexIntegrationMode: session.codexIntegrationMode.map { String(describing: $0) },
          claudeIntegrationMode: session.claudeIntegrationMode.map { String(describing: $0) }
        )
      ),
      usageSource: SessionDetailUsageSource(
        model: session.model,
        inputTokens: session.inputTokens,
        outputTokens: session.outputTokens,
        cachedTokens: session.cachedTokens,
        contextUsed: session.effectiveContextInputTokens,
        totalTokens: session.totalTokens
      ),
      worktreeState: SessionDetailWorktreeState(
        status: session.status,
        isWorktree: session.isWorktree,
        branch: session.branch,
        worktreeId: session.worktreeId,
        projectPath: session.projectPath
      ),
      reviewState: SessionDetailReviewState(
        diff: session.diff,
        cumulativeDiff: session.cumulativeDiff,
        turnDiffs: session.turnDiffs,
        reviewComments: session.reviewComments,
        isDirect: session.isDirect
      ),
      workerState: SessionDetailWorkerState(
        subagents: session.subagents,
        subagentTools: session.subagentTools,
        subagentMessages: session.subagentMessages,
        timelineEntries: session.rowEntries
      ),
      currentTool: session.lastTool,
      lastActivityAt: session.lastActivityAt,
      footerMode: SessionDetailFooterPlanner.mode(
        isDirect: session.isDirect,
        canTakeOver: session.canTakeOver,
        needsApprovalOverlay: session.needsApprovalOverlay
      ),
      sessionStoreEndpointId: endpointId,
      sessionId: sessionId
    )
  }
}

private struct SessionDetailSnapshot {
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

  static let empty = SessionDetailReviewState(
    diff: nil,
    cumulativeDiff: nil,
    turnDiffs: [],
    reviewComments: [],
    isDirect: false
  )
}

struct SessionDetailWorkerState {
  let subagents: [ServerSubagentInfo]
  let subagentTools: [String: [ServerSubagentTool]]
  let subagentMessages: [String: [ServerConversationRowEntry]]
  let timelineEntries: [ServerConversationRowEntry]

  static let empty = SessionDetailWorkerState(
    subagents: [],
    subagentTools: [:],
    subagentMessages: [:],
    timelineEntries: []
  )
}
