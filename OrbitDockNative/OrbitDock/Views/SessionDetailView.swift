//
//  SessionDetailView.swift
//  OrbitDock
//

import OSLog
import SwiftUI

struct SessionDetailView: View {
  @Environment(SessionStore.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.modelPricingService) private var modelPricingService
  @Environment(AppRouter.self) private var router
  let sessionId: String
  let endpointId: UUID

  private var scopedServerState: SessionStore {
    runtimeRegistry.sessionStore(for: endpointId, fallback: serverState)
  }

  private var obs: SessionObservable {
    scopedServerState.session(sessionId)
  }

  @State private var copiedResume = false

  // Chat scroll state
  @State private var isPinned = true
  @State private var unreadCount = 0
  @State private var scrollToBottomTrigger = 0

  @AppStorage("chatViewMode") private var chatViewMode: ChatViewMode = .focused
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OrbitDock", category: "session-detail")
  @State private var selectedSkills: Set<String> = []

  // Layout state for review canvas
  @State private var layoutConfig: LayoutConfiguration = .conversationOnly
  @State private var showDiffBanner = false
  @State private var reviewFileId: String?
  @State private var navigateToComment: ServerReviewComment?
  @State private var selectedCommentIds: Set<String> = []
  @State private var pendingApprovalPanelOpenSignal = 0

  // Worktree cleanup state
  @State private var worktreeCleanupDismissed = false
  @State private var deleteBranchOnCleanup = true
  @State private var isCleaningUpWorktree = false
  @State private var worktreeCleanupError: String?

  private var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }

  private var actionBarState: SessionDetailActionBarState {
    SessionDetailActionBarPlanner.state(
      branch: obs.branch,
      projectPath: obs.projectPath,
      usageStats: usageStats,
      isPinned: isPinned,
      unreadCount: unreadCount,
      lastActivityAt: obs.lastActivityAt
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      // Compact header
      HeaderView(
        sessionId: sessionId,
        endpointId: endpointId,
        onEndSession: obs.isDirect ? { endDirectSession() } : nil,
        layoutConfig: obs.isDirect ? $layoutConfig : nil,
        chatViewMode: $chatViewMode,
        selectedCommentIds: $selectedCommentIds,
        onNavigateToComment: { comment in
          navigateToComment = comment
          withAnimation(Motion.gentle) {
            layoutConfig = SessionDetailLayoutPlanner.nextLayout(
              currentLayout: layoutConfig,
              intent: .revealReviewSplit
            )
          }
        },
        onSendReview: { sendReviewToModel() }
      )

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Diff-available banner
      if showDiffBanner, layoutConfig == .conversationOnly {
        diffAvailableBanner
      }

      // Worktree cleanup banner
      if showWorktreeCleanupBanner {
        worktreeCleanupBanner
      }

      // Main content area — stable structure so ConversationView preserves @State
      HStack(spacing: 0) {
        // Conversation stays in a stable position across layout switches
        if layoutConfig != .reviewOnly {
          conversationContent
            .frame(maxWidth: .infinity)
        }

        // Review canvas (split or full)
        if layoutConfig != .conversationOnly {
          Divider()
            .foregroundStyle(Color.panelBorder)

          ReviewCanvas(
            sessionId: sessionId,
            projectPath: obs.projectPath,
            isSessionActive: obs.isActive,
            compact: layoutConfig == .split,
            navigateToFileId: $reviewFileId,
            onDismiss: {
              withAnimation(Motion.gentle) {
                layoutConfig = SessionDetailLayoutPlanner.nextLayout(
                  currentLayout: layoutConfig,
                  intent: .dismissReview
                )
              }
            },
            selectedCommentIds: $selectedCommentIds,
            navigateToComment: $navigateToComment
          )
          .frame(maxWidth: .infinity)
        }

      }

      // Action bar (unified composer for direct sessions, simpler bar for passive sessions)
      if obs.isDirect {
        DirectSessionComposer(
          sessionId: sessionId,
          selectedSkills: $selectedSkills,
          pendingPanelOpenSignal: pendingApprovalPanelOpenSignal,
          isPinned: $isPinned,
          unreadCount: $unreadCount,
          scrollToBottomTrigger: $scrollToBottomTrigger
        )
      } else {
        if obs.canTakeOver, !obs.needsApprovalOverlay {
          TakeOverInputBar {
            Task { try? await scopedServerState.takeoverSession(sessionId) }
          }
        }
        actionBar
      }
    }
    .background(Color.backgroundPrimary)
    .environment(scopedServerState)
    .onAppear {
      let plan = SessionDetailLifecyclePlanner.onAppearPlan(
        shouldSubscribeToServerSession: shouldSubscribeToServerSession,
        isDirect: obs.isDirect,
        isPinned: isPinned
      )

      if plan.shouldSubscribe {
        // Let SessionStore choose the best recovery path: retained state, cached restore,
        // or full-history recovery when the detail view needs to rebuild after being away.
        scopedServerState.subscribeToSession(sessionId, recoveryGoal: .completeHistory)
        scopedServerState.setSessionAutoMarkRead(sessionId, enabled: plan.autoMarkReadEnabled)
        if plan.shouldLoadApprovalHistory {
          Task {
            if let resp = try? await scopedServerState.clients.approvals.listApprovals(sessionId: sessionId) {
              scopedServerState.session(sessionId).approvalHistory = resp.approvals
            }
          }
        }
      }
    }
    .onDisappear {
      let plan = SessionDetailLifecyclePlanner.onDisappearPlan(
        shouldSubscribeToServerSession: shouldSubscribeToServerSession
      )

      if plan.shouldSetAutoMarkRead {
        scopedServerState.setSessionAutoMarkRead(sessionId, enabled: plan.autoMarkReadEnabled)
      }
      if plan.shouldUnsubscribe {
        scopedServerState.unsubscribeFromSession(sessionId)
      }
    }
    .onChange(of: isPinned) { _, pinned in
      guard let enabled = SessionDetailLifecyclePlanner.autoMarkReadEnabled(
        shouldSubscribeToServerSession: shouldSubscribeToServerSession,
        isPinned: pinned
      ) else {
        return
      }
      scopedServerState.setSessionAutoMarkRead(sessionId, enabled: enabled)
    }
    // Layout keyboard shortcuts
    .onKeyPress(phases: .down) { keyPress in
      guard obs.isDirect else { return .ignored }

      // Cmd+D: Toggle conversation ↔ split
      if keyPress.modifiers == .command, keyPress.key == KeyEquivalent("d") {
        withAnimation(Motion.gentle) {
          layoutConfig = SessionDetailLayoutPlanner.nextLayout(
            currentLayout: layoutConfig,
            intent: .toggleSplitShortcut
          )
        }
        return .handled
      }

      // Cmd+Shift+D: Review only
      if keyPress.modifiers == [.command, .shift], keyPress.key == KeyEquivalent("d") {
        withAnimation(Motion.gentle) {
          layoutConfig = SessionDetailLayoutPlanner.nextLayout(
            currentLayout: layoutConfig,
            intent: .showReviewOnlyShortcut
          )
        }
        return .handled
      }

      // Note: Escape intentionally not used here — ReviewCanvas uses q to close,
      // and Escape is reserved for canceling mark/composer within the canvas.

      return .ignored
    }
    // Diff-available banner trigger
    .onChange(of: scopedServerState.session(sessionId).diff) { oldDiff, newDiff in
      guard SessionDetailLifecyclePlanner.shouldRevealDiffBanner(
        isDirect: obs.isDirect,
        oldDiff: oldDiff,
        newDiff: newDiff,
        layoutConfig: layoutConfig
      ) else {
        return
      }
      withAnimation(Motion.standard) {
        showDiffBanner = true
      }
      // Auto-dismiss after 8 seconds
      Task {
        try? await Task.sleep(for: .seconds(8))
        await MainActor.run {
          withAnimation(Motion.standard) {
            showDiffBanner = false
          }
        }
      }
    }
  }

  private var sessionDetailWorktreeCleanupState: SessionDetailWorktreeCleanupBannerState? {
    SessionDetailWorktreeCleanupPlanner.bannerState(
      status: obs.status,
      isWorktree: obs.isWorktree,
      dismissed: worktreeCleanupDismissed,
      worktree: worktreeForSession,
      branch: obs.branch,
      isCleaningUp: isCleaningUpWorktree
    )
  }

  // MARK: - Action Bar

  private var actionBar: some View {
    Group {
      if isCompactLayout {
        compactActionBar
      } else {
        regularActionBar
      }
    }
  }

  private func openPendingApprovalPanel() {
    let nextState = SessionDetailConversationChromePlanner.openPendingApprovalPanel(
      current: conversationChromeState
    )
    applyConversationChromeState(nextState, animatePendingApprovalPanel: true)
  }

  private var regularActionBar: some View {
    passiveInstrumentStrip
  }

  // MARK: - Passive Instrument Strip

  private var passiveInstrumentStrip: some View {
    SessionDetailRegularActionBar(
      state: actionBarState,
      usageStats: usageStats,
      jumpToLatest: {
        applyConversationChromeState(
          SessionDetailConversationChromePlanner.jumpToLatest(current: conversationChromeState)
        )
      },
      togglePinned: {
        applyConversationChromeState(
          SessionDetailConversationChromePlanner.togglePinned(current: conversationChromeState)
        )
      }
    )
  }

  private var compactActionBar: some View {
    SessionDetailCompactActionBar(
      state: actionBarState,
      usageStats: usageStats,
      canRevealInFileBrowser: Platform.services.capabilities.canRevealInFileBrowser,
      copiedResume: copiedResume,
      onCopyResume: copyResumeCommand,
      onRevealInFinder: {
        _ = Platform.services.revealInFileBrowser(obs.projectPath)
      },
      jumpToLatest: {
        applyConversationChromeState(
          SessionDetailConversationChromePlanner.jumpToLatest(current: conversationChromeState)
        )
      },
      togglePinned: {
        applyConversationChromeState(
          SessionDetailConversationChromePlanner.togglePinned(current: conversationChromeState)
        )
      }
    )
  }

  // MARK: - Conversation Content

  private var conversationContent: some View {
    ConversationView(
      sessionId: sessionId,
      endpointId: endpointId,
      isSessionActive: obs.isActive,
      workStatus: obs.workStatus,
      currentTool: currentTool,
      pendingToolName: obs.pendingToolName,
      pendingPermissionDetail: obs.pendingPermissionDetail,
      provider: obs.provider,
      model: obs.model,
      chatViewMode: chatViewMode,
      onNavigateToReviewFile: { filePath, lineNumber in
        let plan = SessionDetailLayoutPlanner.reviewFileNavigationPlan(
          sessionId: sessionId,
          currentLayout: layoutConfig,
          filePath: filePath,
          lineNumber: lineNumber
        )
        reviewFileId = plan.reviewFileId
        navigateToComment = plan.navigateToComment
        withAnimation(Motion.gentle) {
          layoutConfig = plan.layoutConfig
        }
      },
      onOpenPendingApprovalPanel: {
        openPendingApprovalPanel()
      },
      isPinned: $isPinned,
      unreadCount: $unreadCount,
      scrollToBottomTrigger: $scrollToBottomTrigger
    )
    .environment(\.openFileInReview, obs.isDirect ? { filePath in
      let plan = SessionDetailLayoutPlanner.openFileInReviewPlan(
        projectPath: obs.projectPath,
        currentLayout: layoutConfig,
        filePath: filePath
      )
      reviewFileId = plan.reviewFileId
      withAnimation(Motion.gentle) {
        layoutConfig = plan.layoutConfig
      }
    } : nil)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Diff Available Banner

  private var diffAvailableBanner: some View {
    SessionDetailDiffAvailableBanner(
      fileCount: diffFileCount,
      onRevealReview: {
        let nextLayout = SessionDetailLayoutPlanner.nextLayout(
          currentLayout: layoutConfig,
          intent: .revealReviewSplit
        )
        withAnimation(Motion.gentle) {
          layoutConfig = nextLayout
          showDiffBanner = false
        }
      }
    )
  }

  private var diffFileCount: Int {
    SessionDetailDiffPlanner.fileCount(
      turnDiffs: obs.turnDiffs,
      currentDiff: obs.diff
    )
  }

  // MARK: - Worktree Cleanup

  private var showWorktreeCleanupBanner: Bool {
    sessionDetailWorktreeCleanupState != nil
  }

  private var worktreeForSession: ServerWorktreeSummary? {
    SessionDetailWorktreeCleanupPlanner.resolveWorktree(
      worktreesByRepo: scopedServerState.worktreesByRepo,
      worktreeId: obs.worktreeId,
      projectPath: obs.projectPath
    )
  }

  private var worktreeCleanupBanner: some View {
    SessionDetailWorktreeCleanupBanner(
      bannerState: sessionDetailWorktreeCleanupState,
      errorMessage: worktreeCleanupError,
      deleteBranchOnCleanup: $deleteBranchOnCleanup,
      isCleaningUp: isCleaningUpWorktree,
      onKeep: {
        withAnimation(Motion.gentle) {
          worktreeCleanupDismissed = true
        }
      },
      onCleanUp: {
        cleanUpWorktree()
      }
    )
  }

  private func cleanUpWorktree() {
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
        try await scopedServerState.clients.worktrees.removeWorktree(
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

  private var currentTool: String? {
    obs.lastTool
  }

  private var usageStats: TranscriptUsageStats {
    SessionDetailUsagePlanner.makeStats(
      model: obs.model,
      inputTokens: obs.inputTokens,
      outputTokens: obs.outputTokens,
      cachedTokens: obs.cachedTokens,
      contextUsed: obs.effectiveContextInputTokens,
      totalTokens: obs.totalTokens,
      costCalculator: modelPricingService.calculatorSnapshot
    )
  }

  // MARK: - Helpers

  private var shouldSubscribeToServerSession: Bool {
    // The selected route is authoritative. Loading should not depend on the
    // sessions list already being hydrated on this client.
    !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func copyResumeCommand() {
    let command = "claude --resume \(sessionId)"
    Platform.services.copyToClipboard(command)
    copiedResume = true

    // Reset after visual feedback
    Task {
      try? await Task.sleep(for: .seconds(2))
      await MainActor.run {
        copiedResume = false
      }
    }
  }

  private func endDirectSession() {
    Task { try? await scopedServerState.endSession(sessionId) }
  }

  private var conversationChromeState: SessionDetailConversationChromeState {
    SessionDetailConversationChromeState(
      isPinned: isPinned,
      unreadCount: unreadCount,
      scrollToBottomTrigger: scrollToBottomTrigger,
      pendingApprovalPanelOpenSignal: pendingApprovalPanelOpenSignal
    )
  }

  private func applyConversationChromeState(
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

  // MARK: - Send Review

  private func sendReviewToModel() {
    guard let plan = SessionDetailReviewSendPlanner.makePlan(
      reviewComments: obs.reviewComments,
      selectedCommentIds: selectedCommentIds,
      turnDiffs: obs.turnDiffs,
      currentDiff: obs.diff
    ) else {
      return
    }

    Task {
      try? await scopedServerState.sendMessage(sessionId: sessionId, content: plan.message)

      for commentId in plan.commentIdsToResolve {
        try? await scopedServerState.clients.approvals.updateReviewComment(
          commentId: commentId,
          body: ApprovalsClient.UpdateReviewCommentRequest(status: .resolved)
        )
      }
    }

    // Clear selection after send
    selectedCommentIds.removeAll()
  }
}

#Preview {
  SessionDetailView(
    sessionId: "preview-123",
    endpointId: UUID()
  )
  .environment(SessionStore())
  .environment(AttentionService())
  .environment(AppRouter())
  .frame(width: 800, height: 600)
}
