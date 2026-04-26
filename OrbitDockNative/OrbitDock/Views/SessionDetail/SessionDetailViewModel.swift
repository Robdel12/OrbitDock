import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SessionDetailViewModel {
  private struct BindingContext {
    let sessionId: String
    let endpointId: UUID
    let session: ServerSessionContext
    let revision: Int
  }

  var copiedResume = false
  var currentSessionId = ""
  var currentEndpointId = UUID()
  var currentSession: ServerSessionContext
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
  var capabilities = SessionCapabilitiesModel()
  var conversationViewModel: ConversationViewModel
  var interaction = SessionInteractionModel()

  @ObservationIgnored private weak var modelPricingService: ModelPricingService?
  @ObservationIgnored private let refreshRunner = CoalescedRefreshRunner()
  @ObservationIgnored private var currentBindingRevision = 0
  @ObservationIgnored private var activeSubscriptionIdentity: String?
  @ObservationIgnored private var activeSubscriptionSession: ServerSessionContext?
  @ObservationIgnored private var diffBannerDismissTask: Task<Void, Never>?
  @ObservationIgnored private var pendingInvalidationRevision: UInt64?
  @ObservationIgnored private var lastLoadedRevision: UInt64?
  @ObservationIgnored private var isCapabilitiesVisible = false

  var detailPayload: ServerSessionDetailSnapshotPayload?
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
    session: ServerSessionContext
  ) {
    currentSessionId = sessionId
    currentEndpointId = endpointId
    currentSession = session
    conversationViewModel = ConversationViewModel(
      sessionId: sessionId,
      session: session,
      viewMode: .focused
    )
    bindInteraction(sessionId: sessionId, session: session)
  }

  convenience init() {
    self.init(
      sessionId: "",
      endpointId: UUID(),
      session: ServerSessionContext.preview()
    )
  }

  func bind(
    sessionId: String,
    endpointId: UUID,
    session: ServerSessionContext,
    modelPricingService: ModelPricingService,
    chatViewMode: ChatViewMode = .focused
  ) {
    self.modelPricingService = modelPricingService

    let didSessionChange =
      currentSessionId != sessionId
      || currentEndpointId != endpointId
      || currentSession !== session

    currentSessionId = sessionId
    currentEndpointId = endpointId
    currentSession = session
    conversationViewModel.bind(
      sessionId: sessionId,
      session: session,
      viewMode: chatViewMode
    )
    bindInteraction(sessionId: sessionId, session: session)

    if didSessionChange {
      resetBoundSessionState()
    }
  }

  var sessionId: String {
    currentSessionId
  }

  var endpointId: UUID {
    currentEndpointId
  }

  var session: ServerSessionContext {
    currentSession
  }

  private func bindInteraction(sessionId: String, session: ServerSessionContext) {
    interaction.bind(
      sessionId: sessionId,
      session: session,
      detailSnapshotSink: { [weak self] payload in
        self?.applyDetailPayload(payload)
      },
      conversationRowSink: { [weak self] row in
        self?.applyConversationMutationRow(row)
      }
    )
  }

  private func resetBoundSessionState() {
    currentBindingRevision += 1
    refreshRunner.cancel()
    diffBannerDismissTask?.cancel()
    isCapabilitiesVisible = false
    pendingInvalidationRevision = nil
    lastLoadedRevision = nil
    detailPayload = nil
    conversation.reset()
    review.reset()
    terminal.reset()
    worker.reset()
    cleanup.reset()
    capabilities.reset()
    pendingApprovalPanelOpenSignal = 0
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

  func runLifecycle(
    bindingIdentity: String,
    sessionId: String,
    endpointId: UUID,
    session: ServerSessionContext,
    modelPricingService: ModelPricingService,
    terminalRegistry: TerminalSessionRegistry,
    showWorkerPanel: Bool,
    chatViewMode: ChatViewMode
  ) async {
    let (stream, listenerId) = session.transport.events()
    defer {
      session.transport.removeEventListener(id: listenerId)
      clearSessionSubscription()
    }

    bind(
      sessionId: sessionId,
      endpointId: endpointId,
      session: session,
      modelPricingService: modelPricingService,
      chatViewMode: chatViewMode
    )
    await bootstrapRouteAndSubscribeRealtime(bindingIdentity: bindingIdentity)
    restoreExistingTerminalIfNeeded(from: terminalRegistry)

    if showWorkerPanel {
      handleWorkerPanelVisibilityChange(true)
    }

    for await event in stream {
      guard !Task.isCancelled else { break }
      handleSessionEvent(event)
    }
  }

  private func bootstrapRouteAndSubscribeRealtime(bindingIdentity: String) async {
    // Order matters: conversation HTTP bootstrap records the replay cursor,
    // then the route subscribes before slower selected-session support refreshes.
    await conversationViewModel.refresh()
    reconcileSessionSubscription(bindingIdentity: bindingIdentity)
    await refresh()
  }

  private func handleSessionEvent(_ event: ServerSessionTransport.Event) {
    switch event {
      case let .conversationRowsChanged(delta):
        conversationViewModel.handleConversationRowDelta(delta)
      case let .invalidated(targets):
        handleSessionInvalidation(targets, revision: session.transport.latestRevision)
    }
  }

  private func handleSessionInvalidation(
    _ targets: SessionInvalidationSet,
    revision: UInt64?
  ) {
    if targets.contains(.conversation) {
      conversationViewModel.requestForcedResync(revision: revision)
    }

    if targets.contains(.capabilities) {
      capabilities.markWorkspaceStale()
      refreshCapabilitiesIfVisible(for: capabilities.selectedSection)
    }

    if targets.contains(.skills) {
      capabilities.markStale(.skills)
      refreshCapabilitiesIfVisible(for: .skills)
    }

    if targets.contains(.mcp) {
      capabilities.markStale(.mcp)
      refreshCapabilitiesIfVisible(for: .mcp)
    }

    if targets.contains(.detail) {
      guard SessionSurfaceRefreshPlanner.shouldRequestRefresh(
        snapshotRevision: lastLoadedRevision,
        pendingRevision: pendingInvalidationRevision,
        incomingInvalidationRevision: revision
      ) else { return }
      pendingInvalidationRevision = SessionSurfaceRefreshPlanner.nextPendingRevision(
        pendingRevision: pendingInvalidationRevision,
        incomingInvalidationRevision: revision
      )
      requestRefresh()
    }
  }

  func refresh() async {
    requestRefresh()
    await refreshRunner.waitForCurrentRefresh()
  }

  // MARK: - Follow State (mirrored from TimelineScrollView)

  func handleConversationFollowStateChanged(_ state: ConversationFollowState) {
    conversation.handleFollowStateChanged(state)
  }

  func handleWorkerPanelVisibilityChange(_ visible: Bool) {
    guard visible else {
      worker.cancelDetailLoad()
      return
    }
    worker.loadDetails(
      sessionId: sessionId,
      session: session,
      layoutConfig: layoutConfig
    )
  }

  func handleCapabilitiesVisibilityChange(_ visible: Bool) {
    guard shouldSubscribeToServerSession else { return }
    guard isCapabilitiesVisible != visible else { return }

    isCapabilitiesVisible = visible
    if visible {
      session.transport.subscribe(surfaces: [.capabilities])
    } else {
      session.transport.unsubscribe(surfaces: [.capabilities])
    }
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

  func takeOverSession() async {
    guard let payload = try? await session.api.takeoverSession(
      model: nil,
      approvalPolicyDetails: nil,
      sandboxPolicyDetails: nil,
      permissionMode: nil,
      collaborationMode: nil,
      multiAgent: nil,
      personality: nil,
      serviceTier: nil,
      developerInstructions: nil
    ) else { return }
    applyDetailPayload(payload)
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
    guard SessionDetailDiffBannerPlanner.shouldRevealForFirstDiff(
      isDirect: reviewState.isDirect,
      oldDiff: oldDiff,
      newDiff: newDiff,
      layoutConfig: layoutConfig
    ) else {
      return false
    }
    presentDiffBanner()
    return true
  }

  func handleReviewTurnCountChange(oldCount: UInt64, newCount: UInt64) -> Bool {
    guard SessionDetailDiffBannerPlanner.shouldRevealForNewReviewTurn(
      isDirect: reviewState.isDirect,
      oldCount: oldCount,
      newCount: newCount,
      layoutConfig: layoutConfig
    ) else {
      return false
    }
    presentDiffBanner()
    return true
  }

  func copyResumeCommand() {
    let command = screenPresentation.provider.resumeCommand(sessionId: sessionId)
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
    Task {
      if let payload = try? await session.api.endSession() {
        await MainActor.run {
          applyDetailPayload(payload)
        }
      }
    }
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
      _ = try? await session.api.sendMessage(content: plan.message)

      for commentId in plan.commentIdsToResolve {
        _ = try? await session.api.updateReviewComment(
          commentId: commentId,
          body: ApprovalsClient.UpdateReviewCommentRequest(status: .resolved)
        )
      }
    }

    review.selectedCommentIds.removeAll()
  }

  func applyDetailPayload(_ payload: ServerSessionDetailSnapshotPayload) {
    guard payload.session.id == sessionId else { return }
    if let currentRevision = detailPayload?.revision, payload.revision < currentRevision {
      return
    }
    session.transport.recordRevision(payload.revision)
    lastLoadedRevision = max(lastLoadedRevision ?? payload.revision, payload.revision)
    if let pendingInvalidationRevision, pendingInvalidationRevision <= payload.revision {
      self.pendingInvalidationRevision = nil
    }
    detailPayload = payload
    capabilities.syncSessionState(payload.session)
    interaction.applyOwnerDetailSnapshot(
      payload,
      source: "session_detail_owner"
    )
    apply(snapshot: SessionDetailSnapshotBuilder.build(
      payload: payload,
      endpointId: endpointId,
      sourceServerInstanceId: session.serverInstanceId,
      sourceIsRemoteConnection: session.isRemoteConnection
    ))
  }

  func applyConversationMutationRow(_ row: ServerConversationRowEntry) {
    guard row.sessionId == sessionId else { return }
    conversationViewModel.handleConversationRowDelta(
      .init(upserted: [row], removedIds: [])
    )
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

  private func reconcileSessionSubscription(bindingIdentity: String) {
    guard shouldSubscribeToServerSession else {
      clearSessionSubscription()
      return
    }

    guard activeSubscriptionIdentity != bindingIdentity else { return }
    clearSessionSubscription()
    session.transport.subscribe(surfaces: [.detail, .conversation])
    activeSubscriptionIdentity = bindingIdentity
    activeSubscriptionSession = session
  }

  func clearSessionSubscription() {
    refreshRunner.cancel()
    diffBannerDismissTask?.cancel()
    pendingInvalidationRevision = nil
    activeSubscriptionSession?.transport.unsubscribe(surfaces: [.capabilities])
    isCapabilitiesVisible = false
    activeSubscriptionSession?.transport.unsubscribe(surfaces: [.detail, .conversation])
    activeSubscriptionSession = nil
    activeSubscriptionIdentity = nil
  }

  private func restoreExistingTerminalIfNeeded(from terminalRegistry: TerminalSessionRegistry) {
    guard terminal.activeTerminalId == nil else { return }
    let prefix = "term-\(sessionId)-"
    guard let existingId = terminalRegistry.sessions.keys.first(where: { $0.hasPrefix(prefix) }) else { return }
    terminal.activeTerminalId = existingId
    terminal.showPanel = true
  }

  private func presentDiffBanner() {
    withAnimation(Motion.standard) {
      review.showDiffBanner = true
    }

    diffBannerDismissTask?.cancel()
    diffBannerDismissTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(8))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self else { return }
        withAnimation(Motion.standard) {
          self.review.showDiffBanner = false
        }
        self.diffBannerDismissTask = nil
      }
    }
  }

  private func requestRefresh() {
    refreshRunner.schedule { [weak self] in
      await self?.performRefresh()
    }
  }

  private func refreshCapabilitiesIfVisible(for section: SessionCapabilitiesSection) {
    guard capabilities.visibleSections.contains(section) else { return }

    let projectPath = detailPayload?.session.projectPath ?? screenPresentation.projectPath
    let sessionState = detailPayload?.session

    Task { [weak self] in
      guard let self else { return }
      await self.capabilities.loadIfNeeded(
        session: self.session,
        projectPath: projectPath,
        sessionState: sessionState,
        section: section
      )
    }
  }

  private func performRefresh() async {
    guard shouldSubscribeToServerSession else {
      detailPayload = nil
      apply(snapshot: .empty(endpointId: endpointId, sessionId: sessionId))
      return
    }

    guard let binding = currentBindingContext else { return }
    if let pendingInvalidationRevision,
       let lastLoadedRevision,
       pendingInvalidationRevision <= lastLoadedRevision
    {
      self.pendingInvalidationRevision = nil
      return
    }

    do {
      let payload = try await binding.session.api.fetchSessionDetail()
      guard isCurrent(binding) else { return }
      applyDetailPayload(payload)
    } catch {
      pendingInvalidationRevision = nil
      // Non-fatal: the view keeps showing the last snapshot
    }
  }

  private var currentBindingContext: BindingContext? {
    guard shouldSubscribeToServerSession else { return nil }
    return BindingContext(
      sessionId: sessionId,
      endpointId: endpointId,
      session: session,
      revision: currentBindingRevision
    )
  }

  private func isCurrent(_ binding: BindingContext) -> Bool {
    sessionId == binding.sessionId
      && endpointId == binding.endpointId
      && session === binding.session
      && currentBindingRevision == binding.revision
  }
}
