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
  @State var selectedWorkerId: String?
  @State var conversationJumpTarget: ConversationJumpTarget?

  // Chat scroll state
  @State var isPinned = true
  @State var unreadCount = 0
  @State var scrollToBottomTrigger = 0

  @AppStorage("chatViewMode") var chatViewMode: ChatViewMode = .focused
  @AppStorage("sessionDetail.showWorkerPanel") var showWorkerPanel = true
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
        workerPanelVisible: $showWorkerPanel,
        hasWorkerPanelContent: workerRosterPresentation != nil,
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
      } companion: {
        workerCompanionPanel
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
    .onAppear(perform: handleOnAppear)
    .onDisappear(perform: handleOnDisappear)
    .onChange(of: isPinned) { _, pinned in
      handlePinnedChange(pinned)
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
      handleDiffChange(oldDiff: oldDiff, newDiff: newDiff)
    }
    .onChange(of: workerSelectionSignature) { _, _ in
      syncSelectedWorker()
    }
    .onChange(of: selectedWorkerId) { _, _ in
      loadSelectedWorkerTools()
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
