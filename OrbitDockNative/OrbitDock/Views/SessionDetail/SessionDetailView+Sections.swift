import SwiftUI

extension SessionDetailView {
  var workerRosterPresentation: SessionWorkerRosterPresentation? {
    viewModel.worker.rosterPresentation
  }

  var workerDetailPresentation: SessionWorkerDetailPresentation? {
    guard showWorkerPanel else { return nil }
    return viewModel.worker.detailPresentation
  }

  @ViewBuilder
  var workerCompanionPanel: some View {
    let isVisible = showWorkerPanel && workerRosterPresentation != nil

    SessionDetailCompanionPane(isVisible: isVisible, width: 320) {
      if let workerRosterPresentation {
        SessionWorkerCompanionPanel(
          rosterPresentation: workerRosterPresentation,
          detailPresentation: workerDetailPresentation,
          selectedWorkerID: viewModel.worker.selectedWorkerId,
          onSelectWorker: { workerId in
            selectWorkerInPanel(workerId)
          },
          onRevealConversationEvent: { messageId in
            withAnimation(Motion.gentle) {
              viewModel.revealWorkerConversationEvent(messageId)
            }
          }
        )
      }
    }
  }

  var regularActionBar: some View {
    passiveInstrumentStrip
  }

  var passiveInstrumentStrip: some View {
    SessionDetailRegularActionBar(
      state: actionBarState,
      usageStats: usageStats,
      jumpToLatest: viewModel.jumpConversationToLatest,
      togglePinned: viewModel.toggleConversationFollowMode
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
      jumpToLatest: viewModel.jumpConversationToLatest,
      togglePinned: viewModel.toggleConversationFollowMode
    )
  }

  var conversationContent: some View {
    let presentation = viewModel.conversationPresentation

    return SessionDetailConversationSection(
      sessionId: sessionId,
      session: scopedSession,
      viewModel: viewModel.conversationViewModel,
      endpointId: endpointId,
      isSessionActive: presentation.isSessionActive,
      displayStatus: presentation.displayStatus,
      currentTool: presentation.currentTool,
      showsOrbitStatusIndicator: !screenPresentation.isDirect,
      chatViewMode: chatViewMode,
      openFileInReview: presentation.canOpenFileInReview ? { filePath in
        withAnimation(Motion.gentle) {
          viewModel.openFileInReview(projectPath: presentation.projectPath, filePath: filePath)
        }
      } : nil,
      focusWorkerInDeck: workerRosterPresentation != nil ? { workerId in
        focusWorkerInDeck(workerId)
      } : nil,
      rewindToMessage: { messageId in
        Task {
          await viewModel.interaction.rewindToMessage(messageId)
        }
      },
      stopTarget: { targetId in
        Task {
          await viewModel.interaction.stopTarget(targetId)
        }
      },
      scrollCommand: $viewModel.conversation.scrollCommand,
      onJumpToLatest: viewModel.jumpConversationToLatest,
      onFollowStateChanged: viewModel.handleConversationFollowStateChanged
    )
  }

  var reviewCanvas: some View {
    let presentation = viewModel.reviewPresentation

    return SessionDetailReviewSection(
      sessionId: sessionId,
      session: scopedSession,
      projectPath: presentation.projectPath,
      isSessionActive: presentation.isSessionActive,
      compact: presentation.compact,
      reviewFileId: $viewModel.review.reviewFileId,
      selectedCommentIds: $viewModel.review.selectedCommentIds,
      navigateToComment: $viewModel.review.navigateToComment,
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
    sessionDetailWorktreeCleanupState != nil
  }

  var worktreeCleanupBanner: some View {
    SessionDetailWorktreeCleanupBanner(
      bannerState: sessionDetailWorktreeCleanupState,
      errorMessage: viewModel.cleanup.errorMessage,
      deleteBranchOnCleanup: $viewModel.cleanup.deleteBranchOnCleanup,
      isCleaningUp: viewModel.cleanup.isCleaningUp,
      onKeep: {
        withAnimation(Motion.gentle) {
          viewModel.cleanup.dismiss()
        }
      },
      onCleanUp: {
        viewModel.cleanup.cleanUp(
          worktreeState: viewModel.worktreeState,
          worktreesByRepo: scopedSession.worktreesByRepo,
          session: scopedSession
        )
      }
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

  var sessionDetailWorktreeCleanupState: SessionDetailWorktreeCleanupBannerState? {
    viewModel.cleanup.bannerState(
      worktreeState: viewModel.worktreeState,
      worktreesByRepo: scopedSession.worktreesByRepo
    )
  }
}
