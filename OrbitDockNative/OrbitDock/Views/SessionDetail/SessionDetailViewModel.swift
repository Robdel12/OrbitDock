import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SessionDetailViewModel {
  var copiedResume = false
  var currentSessionId = ""
  var currentEndpointId = UUID()
  var currentSessionStore: SessionStore
  var layoutConfig: LayoutConfiguration = .conversationOnly {
    didSet {
      syncSectionPresentations()
      worker.syncLayout(layoutConfig)
    }
  }

  var pendingApprovalPanelOpenSignal = 0
  var conversation = SessionDetailConversationModel()
  var review = SessionDetailReviewModel()
  var terminal = SessionDetailTerminalModel()
  var worker = SessionDetailWorkerModel()
  var cleanup = SessionDetailWorktreeCleanupModel()

  @ObservationIgnored private weak var modelPricingService: ModelPricingService?
  @ObservationIgnored private var isRefreshing = false
  @ObservationIgnored private var refreshQueued = false

  var screenPresentation = SessionDetailScreenPresentation.empty
  var usageSource = SessionDetailUsageSource.empty
  var worktreeState = SessionDetailWorktreeState.empty
  var reviewState = SessionDetailReviewState.empty
  var conversationPresentation = SessionDetailConversationSectionPresentation.empty
  var reviewPresentation = SessionDetailReviewSectionPresentation.empty
  var footerMode: SessionDetailFooterMode = .passive
  var currentTool: String?
  var lastActivityAt: Date?

  init(
    sessionId: String,
    endpointId: UUID,
    sessionStore: SessionStore
  ) {
    currentSessionId = sessionId
    currentEndpointId = endpointId
    currentSessionStore = sessionStore
  }

  convenience init() {
    self.init(
      sessionId: "",
      endpointId: UUID(),
      sessionStore: SessionStore.preview()
    )
  }

  func bind(
    sessionId: String,
    endpointId: UUID,
    sessionStore: SessionStore,
    modelPricingService: ModelPricingService
  ) {
    self.modelPricingService = modelPricingService

    let didSessionChange =
      currentSessionId != sessionId
      || currentEndpointId != endpointId
      || currentSessionStore !== sessionStore

    currentSessionId = sessionId
    currentEndpointId = endpointId
    currentSessionStore = sessionStore

    if didSessionChange {
      conversation.reset()
      review.reset()
      terminal.reset()
      worker.reset()
      cleanup.reset()
      pendingApprovalPanelOpenSignal = 0
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

  var followMode: ConversationFollowMode {
    conversation.followState.mode
  }

  var unreadCount: Int {
    conversation.followState.unreadCount
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

    let targetSessionId = sessionId
    let targetEndpointId = endpointId
    let targetStore = sessionStore

    do {
      let payload = try await targetStore.clients.conversation.fetchSessionDetail(targetSessionId)
      guard sessionId == targetSessionId,
            endpointId == targetEndpointId,
            sessionStore === targetStore
      else { return }
      apply(snapshot: SessionDetailSnapshotBuilder.build(
        payload: payload,
        endpointId: targetEndpointId,
        sourceServerInstanceId: targetStore.serverInstanceId,
        sourceIsRemoteConnection: targetStore.isRemoteConnection
      ))
    } catch {
      // Non-fatal: the view keeps showing the last snapshot
    }
  }

  // MARK: - Follow State (mirrored from TimelineScrollView)

  func handleConversationFollowStateChanged(_ state: ConversationFollowState) {
    conversation.handleFollowStateChanged(state)
  }

  func jumpConversationToLatest() {
    conversation.jumpToLatest()
  }

  func toggleConversationFollowMode() {
    conversation.toggleFollowMode()
  }

  func openPendingApprovalPanel() {
    withAnimation(Motion.standard) {
      pendingApprovalPanelOpenSignal += 1
    }
    conversation.openPendingApproval()
  }

  func navigateToReviewComment(_ comment: ServerReviewComment) {
    review.navigateToComment = comment
    revealReview()
  }

  func openFileInReview(projectPath: String, filePath: String) {
    let plan = SessionDetailLayoutPlanner.openFileInReviewPlan(
      projectPath: projectPath,
      currentLayout: layoutConfig,
      filePath: filePath
    )
    review.reviewFileId = plan.reviewFileId
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
    review.showDiffBanner = false
  }

  func revealWorkerConversationEvent(_ messageId: String) {
    if layoutConfig == .reviewOnly {
      layoutConfig = .split
    }
    conversation.revealMessage(id: messageId)
  }

  func selectLayout(_ layout: LayoutConfiguration) {
    layoutConfig = layout
  }

  func handleDiffChange(oldDiff: String?, newDiff: String?) -> Bool {
    guard reviewState.isDirect, oldDiff == nil, newDiff != nil, layoutConfig == .conversationOnly else {
      return false
    }
    review.showDiffBanner = true
    return true
  }

  func handleReviewTurnCountChange(oldCount: UInt64, newCount: UInt64) -> Bool {
    guard reviewState.isDirect, newCount > oldCount, layoutConfig == .conversationOnly else {
      return false
    }
    review.showDiffBanner = true
    return true
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

  func sendReviewToModel() {
    guard let plan = SessionDetailReviewSendPlanner.makePlan(
      reviewComments: reviewState.reviewComments,
      selectedCommentIds: review.selectedCommentIds,
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

    review.selectedCommentIds.removeAll()
  }

  private func apply(snapshot: SessionDetailSnapshot) {
    screenPresentation = snapshot.screenPresentation
    usageSource = snapshot.usageSource
    worktreeState = snapshot.worktreeState
    reviewState = snapshot.reviewState
    worker.apply(snapshotState: snapshot.workerState, layoutConfig: layoutConfig)
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
}
