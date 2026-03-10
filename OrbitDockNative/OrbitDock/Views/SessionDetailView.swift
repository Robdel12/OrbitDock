//
//  SessionDetailView.swift
//  OrbitDock
//

import OSLog
import SwiftUI

struct SessionDetailView: View {
  @Environment(SessionStore.self) var serverState
  @Environment(ServerRuntimeRegistry.self) var runtimeRegistry
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  @Environment(\.modelPricingService) var modelPricingService
  @Environment(AppRouter.self) var router
  let sessionId: String
  let endpointId: UUID

  var scopedServerState: SessionStore {
    runtimeRegistry.sessionStore(for: endpointId, fallback: serverState)
  }

  var obs: SessionObservable {
    scopedServerState.session(sessionId)
  }

  @State var copiedResume = false

  // Chat scroll state
  @State var isPinned = true
  @State var unreadCount = 0
  @State var scrollToBottomTrigger = 0

  @AppStorage("chatViewMode") var chatViewMode: ChatViewMode = .focused
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OrbitDock", category: "session-detail")
  @State var selectedSkills: Set<String> = []

  // Layout state for review canvas
  @State var layoutConfig: LayoutConfiguration = .conversationOnly
  @State var showDiffBanner = false
  @State var reviewFileId: String?
  @State var navigateToComment: ServerReviewComment?
  @State var selectedCommentIds: Set<String> = []
  @State var pendingApprovalPanelOpenSignal = 0

  // Worktree cleanup state
  @State var worktreeCleanupDismissed = false
  @State var deleteBranchOnCleanup = true
  @State var isCleaningUpWorktree = false
  @State var worktreeCleanupError: String?

  var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }

  var actionBarState: SessionDetailActionBarState {
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

      SessionDetailMainContentArea(layoutConfig: layoutConfig) {
        conversationContent
      } review: {
        reviewCanvas
      }

      SessionDetailFooter(mode: footerMode) {
        DirectSessionComposer(
          sessionId: sessionId,
          selectedSkills: $selectedSkills,
          pendingPanelOpenSignal: pendingApprovalPanelOpenSignal,
          isPinned: $isPinned,
          unreadCount: $unreadCount,
          scrollToBottomTrigger: $scrollToBottomTrigger
        )
      } takeOverBar: {
        TakeOverInputBar {
          Task { try? await scopedServerState.takeoverSession(sessionId) }
        }
      } passiveActionBar: {
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
      guard let command = SessionDetailShortcutPlanner.command(
        isDirect: obs.isDirect,
        modifiers: keyPress.modifiers,
        key: keyPress.key
      ) else {
        return .ignored
      }

      withAnimation(Motion.gentle) {
        layoutConfig = SessionDetailShortcutPlanner.nextLayout(
          currentLayout: layoutConfig,
          command: command
        )
      }
      return .handled
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

  var sessionDetailWorktreeCleanupState: SessionDetailWorktreeCleanupBannerState? {
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

  var actionBar: some View {
    Group {
      if isCompactLayout {
        compactActionBar
      } else {
        regularActionBar
      }
    }
  }

  // Remaining sections and imperative handlers live in companion files so this root
  // stays focused on feature composition and lifecycle wiring.

  // MARK: - Helpers

  var shouldSubscribeToServerSession: Bool {
    // The selected route is authoritative. Loading should not depend on the
    // sessions list already being hydrated on this client.
    !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var conversationChromeState: SessionDetailConversationChromeState {
    SessionDetailConversationChromeState(
      isPinned: isPinned,
      unreadCount: unreadCount,
      scrollToBottomTrigger: scrollToBottomTrigger,
      pendingApprovalPanelOpenSignal: pendingApprovalPanelOpenSignal
    )
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
