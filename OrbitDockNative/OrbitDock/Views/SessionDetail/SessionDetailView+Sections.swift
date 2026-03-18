import SwiftUI

extension SessionDetailView {
  var workerRosterPresentation: SessionWorkerRosterPresentation? {
    SessionWorkerRosterPlanner.presentation(subagents: obs.subagents)
  }

  var workerDetailPresentation: SessionWorkerDetailPresentation? {
    guard showWorkerPanel, let selectedWorkerId else { return nil }

    let hasLoadedWorkerPayload =
      obs.subagentTools[selectedWorkerId] != nil || obs.subagentMessages[selectedWorkerId] != nil

    guard hasLoadedWorkerPayload else { return nil }

    return SessionWorkerRosterPlanner.detailPresentation(
      subagents: obs.subagents,
      selectedWorkerID: selectedWorkerId,
      toolsByWorker: obs.subagentTools,
      messagesByWorker: obs.subagentMessages,
      timelineMessages: scopedServerState.conversation(sessionId).messages
    )
  }

  var workerSelectionSignature: [String] {
    obs.subagents.map {
      [
        $0.id,
        $0.status?.rawValue ?? "none",
        $0.lastActivityAt ?? "",
      ].joined(separator: "|")
    }
  }

  @ViewBuilder
  var workerCompanionPanel: some View {
    if let workerRosterPresentation, showWorkerPanel {
      Divider()
        .foregroundStyle(Color.panelBorder)

      SessionWorkerCompanionPanel(
        rosterPresentation: workerRosterPresentation,
        detailPresentation: workerDetailPresentation,
        selectedWorkerID: selectedWorkerId,
        onSelectWorker: { workerId in
          selectWorkerInPanel(workerId)
        },
        onRevealConversationEvent: { messageId in
          if layoutConfig == .reviewOnly {
            withAnimation(Motion.gentle) {
              layoutConfig = .split
            }
          }
          isPinned = false
          conversationJumpTarget = .init(messageID: messageId, nonce: (conversationJumpTarget?.nonce ?? 0) + 1)
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
      copiedResume: copiedResume,
      onCopyResume: copyResumeCommand,
      onRevealInFinder: {
        _ = Platform.services.revealInFileBrowser(obs.projectPath)
      },
      jumpToLatest: jumpConversationToLatest,
      togglePinned: toggleConversationPinnedState
    )
  }

  var conversationContent: some View {
    SessionDetailConversationSection(
      sessionId: sessionId,
      endpointId: endpointId,
      isSessionActive: obs.isActive,
      workStatus: obs.workStatus,
      displayStatus: obs.displayStatus,
      currentTool: currentTool,
      pendingToolName: obs.pendingToolName,
      pendingPermissionDetail: obs.pendingPermissionDetail,
      provider: obs.provider,
      model: obs.model,
      selectedWorkerID: selectedWorkerId,
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
      onOpenPendingApprovalPanel: openPendingApprovalPanel,
      openFileInReview: obs.isDirect ? { filePath in
        let plan = SessionDetailLayoutPlanner.openFileInReviewPlan(
          projectPath: obs.projectPath,
          currentLayout: layoutConfig,
          filePath: filePath
        )
        reviewFileId = plan.reviewFileId
        withAnimation(Motion.gentle) {
          layoutConfig = plan.layoutConfig
        }
      } : nil,
      focusWorkerInDeck: workerRosterPresentation != nil ? { workerId in
        focusWorkerInDeck(workerId)
      } : nil,
      jumpToMessageTarget: $conversationJumpTarget,
      isPinned: $isPinned,
      unreadCount: $unreadCount,
      scrollToBottomTrigger: $scrollToBottomTrigger
    )
  }

  var reviewCanvas: some View {
    SessionDetailReviewSection(
      sessionId: sessionId,
      projectPath: obs.projectPath,
      isSessionActive: obs.isActive,
      compact: layoutConfig == .split,
      reviewFileId: $reviewFileId,
      selectedCommentIds: $selectedCommentIds,
      navigateToComment: $navigateToComment,
      onDismiss: {
        withAnimation(Motion.gentle) {
          layoutConfig = SessionDetailLayoutPlanner.nextLayout(
            currentLayout: layoutConfig,
            intent: .dismissReview
          )
        }
      }
    )
  }

  var diffAvailableBanner: some View {
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

  var diffFileCount: Int {
    SessionDetailDiffPlanner.fileCount(
      turnDiffs: obs.turnDiffs,
      currentDiff: obs.diff
    )
  }

  var showWorktreeCleanupBanner: Bool {
    sessionDetailWorktreeCleanupState != nil
  }

  var worktreeForSession: ServerWorktreeSummary? {
    SessionDetailWorktreeCleanupPlanner.resolveWorktree(
      worktreesByRepo: scopedServerState.worktreesByRepo,
      worktreeId: obs.worktreeId,
      projectPath: obs.projectPath
    )
  }

  var worktreeCleanupBanner: some View {
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
      onCleanUp: cleanUpWorktree
    )
  }

  var currentTool: String? {
    obs.lastTool
  }

  var usageStats: TranscriptUsageStats {
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

  var footerMode: SessionDetailFooterMode {
    SessionDetailFooterPlanner.mode(
      isDirect: obs.isDirect,
      canTakeOver: obs.canTakeOver,
      needsApprovalOverlay: obs.needsApprovalOverlay
    )
  }
}
