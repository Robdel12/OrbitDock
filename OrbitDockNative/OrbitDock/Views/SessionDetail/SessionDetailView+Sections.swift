import SwiftUI

extension SessionDetailView {
  var workerRosterPresentation: SessionWorkerRosterPresentation? {
    viewModel.workerRosterPresentation
  }

  var workerDetailPresentation: SessionWorkerDetailPresentation? {
    guard showWorkerPanel else { return nil }
    return viewModel.workerDetailPresentation
  }

  var workerSelectionSignature: [String] {
    viewModel.workerSelectionSignature
  }

  @ViewBuilder
  var workerCompanionPanel: some View {
    if let workerRosterPresentation, showWorkerPanel {
      Divider()
        .foregroundStyle(Color.panelBorder)

      SessionWorkerCompanionPanel(
        rosterPresentation: workerRosterPresentation,
        detailPresentation: workerDetailPresentation,
        selectedWorkerID: viewModel.selectedWorkerId,
        onSelectWorker: { workerId in
          selectWorkerInPanel(workerId)
        },
        onRevealConversationEvent: { messageId in
          withAnimation(Motion.gentle) {
            viewModel.revealWorkerConversationEvent(messageId)
          }
        }
      )
      .frame(width: 320)
      .background(Color.panelBackground)
    } else {
      EmptyView()
    }
  }

  var regularActionBar: some View {
    passiveInstrumentStrip
  }

  var passiveInstrumentStrip: some View {
    SessionDetailRegularActionBar(
      state: actionBarState,
      usageStats: usageStats,
      jumpToLatest: jumpConversationToLatest,
      togglePinned: toggleConversationPinnedState
    )
  }

  var passiveStatusStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm) {
        ContextGaugeCompact(stats: usageStats)

        if let formattedCost = actionBarState.formattedCost {
          Text(formattedCost)
            .font(.system(size: TypeScale.code, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary.opacity(OpacityTier.vivid))
        }

        if let branchLabel = actionBarState.branchLabel {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.triangle.branch")
              .font(.system(size: TypeScale.caption, weight: .semibold))
            Text(branchLabel)
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
          }
          .foregroundStyle(Color.gitBranch)
        }

        if let lastActivityAt = actionBarState.lastActivityAt {
          Text(lastActivityAt, style: .relative)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm_)
    }
    .scrollIndicators(.hidden)
  }

  var compactActionBar: some View {
    SessionDetailCompactActionBar(
      state: actionBarState,
      usageStats: usageStats,
      canRevealInFileBrowser: Platform.services.capabilities.canRevealInFileBrowser,
      copiedResume: viewModel.copiedResume,
      onCopyResume: viewModel.copyResumeCommand,
      onRevealInFinder: {
        _ = Platform.services.revealInFileBrowser(screenPresentation.projectPath)
      },
      jumpToLatest: jumpConversationToLatest,
      togglePinned: toggleConversationPinnedState
    )
  }

  var conversationContent: some View {
    let presentation = viewModel.conversationPresentation

    return SessionDetailConversationSection(
      sessionId: presentation.sessionId,
      sessionStore: scopedServerState,
      endpointId: presentation.endpointId,
      isSessionActive: presentation.isSessionActive,
      displayStatus: presentation.displayStatus,
      currentTool: presentation.currentTool,
      chatViewMode: chatViewMode,
      openFileInReview: presentation.canOpenFileInReview ? { filePath in
        withAnimation(Motion.gentle) {
          viewModel.openFileInReview(projectPath: presentation.projectPath, filePath: filePath)
        }
      } : nil,
      focusWorkerInDeck: workerRosterPresentation != nil ? { workerId in
        focusWorkerInDeck(workerId)
      } : nil,
      jumpToMessageTarget: $viewModel.conversationJumpTarget,
      isPinned: $viewModel.isPinned,
      unreadCount: $viewModel.unreadCount,
      scrollToBottomTrigger: $viewModel.scrollToBottomTrigger
    )
  }

  var reviewCanvas: some View {
    let presentation = viewModel.reviewPresentation

    return SessionDetailReviewSection(
      sessionId: presentation.sessionId,
      sessionStore: scopedServerState,
      projectPath: presentation.projectPath,
      isSessionActive: presentation.isSessionActive,
      compact: presentation.compact,
      reviewFileId: $viewModel.reviewFileId,
      selectedCommentIds: $viewModel.selectedCommentIds,
      navigateToComment: $viewModel.navigateToComment,
      onDismiss: {
        withAnimation(Motion.gentle) {
          viewModel.dismissReview()
        }
      }
    )
  }

  var diffAvailableBanner: some View {
    SessionDetailDiffAvailableBanner(
      fileCount: diffFileCount,
      onRevealReview: {
        withAnimation(Motion.gentle) {
          viewModel.revealReview()
        }
      }
    )
  }

  var diffFileCount: Int {
    viewModel.diffFileCount
  }

  var showWorktreeCleanupBanner: Bool {
    viewModel.showWorktreeCleanupBanner
  }

  var worktreeForSession: ServerWorktreeSummary? {
    viewModel.worktreeForSession
  }

  var worktreeCleanupBanner: some View {
    SessionDetailWorktreeCleanupBanner(
      bannerState: sessionDetailWorktreeCleanupState,
      errorMessage: viewModel.worktreeCleanupError,
      deleteBranchOnCleanup: $viewModel.deleteBranchOnCleanup,
      isCleaningUp: viewModel.isCleaningUpWorktree,
      onKeep: {
        withAnimation(Motion.gentle) {
          viewModel.worktreeCleanupDismissed = true
        }
      },
      onCleanUp: viewModel.cleanUpWorktree
    )
  }

  var currentTool: String? {
    viewModel.currentTool
  }

  var usageStats: TranscriptUsageStats {
    viewModel.usageStats
  }

  var footerMode: SessionDetailFooterMode {
    viewModel.footerMode
  }
}
