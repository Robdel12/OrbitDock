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
    withAnimation(Motion.standard) {
      pendingApprovalPanelOpenSignal += 1
    }
    isPinned = true
    unreadCount = 0
    scrollToBottomTrigger += 1
  }

  private var regularActionBar: some View {
    passiveInstrumentStrip
  }

  // MARK: - Passive Instrument Strip

  private var passiveInstrumentStrip: some View {
    HStack(spacing: 0) {
      // Git branch
      if let branch = obs.branch, !branch.isEmpty {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: TypeScale.micro, weight: .semibold))
          Text(compactBranchLabel(branch))
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(Color.gitBranch)
        .padding(.horizontal, Spacing.md)

        stripDivider
      }

      // Project path
      Text(compactProjectPath(obs.projectPath))
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .foregroundStyle(Color.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, Spacing.md)

      Spacer()

      // Cost
      if usageStats.estimatedCostUSD > 0 {
        Text(usageStats.formattedCost)
          .font(.system(size: TypeScale.caption, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, Spacing.md)

        stripDivider
      }

      // Context gauge
      ContextGaugeCompact(stats: usageStats)
        .padding(.horizontal, Spacing.md)

      stripDivider

      // Scroll state / new messages
      if !isPinned, unreadCount > 0 {
        Button {
          isPinned = true
          unreadCount = 0
          scrollToBottomTrigger += 1
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.down")
              .font(.system(size: TypeScale.micro, weight: .bold))
            Text("\(unreadCount) new")
              .font(.system(size: TypeScale.caption, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(Color.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.sm)
        .transition(.scale.combined(with: .opacity))
      }

      Button {
        isPinned.toggle()
        if isPinned {
          unreadCount = 0
          scrollToBottomTrigger += 1
        }
      } label: {
        Text(isPinned ? "Following" : "Paused")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(isPinned ? Color.textTertiary : Color.textPrimary)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, Spacing.md)
    }
    .frame(height: 30)
    .background(Color.backgroundSecondary)
    .animation(Motion.standard, value: isPinned)
    .animation(Motion.standard, value: unreadCount)
  }

  private var stripDivider: some View {
    Color.panelBorder.opacity(0.38)
      .frame(width: 1, height: 14)
  }

  private var compactActionBar: some View {
    VStack(spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        Button {
          copyResumeCommand()
        } label: {
          Image(systemName: copiedResume ? "checkmark" : "doc.on.doc")
            .font(.system(size: TypeScale.code, weight: .medium))
            .frame(width: 30, height: 30)
            .foregroundStyle(copiedResume ? Color.feedbackPositive : .secondary)
            .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Copy resume command")

        if Platform.services.capabilities.canRevealInFileBrowser {
          Button {
            _ = Platform.services.revealInFileBrowser(obs.projectPath)
          } label: {
            Image(systemName: "folder")
              .font(.system(size: TypeScale.code, weight: .medium))
              .frame(width: 30, height: 30)
              .foregroundStyle(.secondary)
              .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
          }
          .buttonStyle(.plain)
          .help("Open in Finder")
        }

        Spacer(minLength: 0)

        if !isPinned, unreadCount > 0 {
          Button {
            isPinned = true
            unreadCount = 0
            scrollToBottomTrigger += 1
          } label: {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "arrow.down")
                .font(.system(size: TypeScale.caption, weight: .bold))
              Text("\(unreadCount)")
                .font(.system(size: TypeScale.code, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.accent, in: Capsule())
          }
          .buttonStyle(.plain)
          .transition(.scale.combined(with: .opacity))
        }

        Button {
          isPinned.toggle()
          if isPinned {
            unreadCount = 0
            scrollToBottomTrigger += 1
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: isPinned ? "arrow.down.to.line" : "pause")
              .font(.system(size: TypeScale.body, weight: .medium))
            Text(isPinned ? "Following" : "Paused")
              .font(.system(size: TypeScale.code, weight: .medium))
          }
          .foregroundStyle(isPinned ? .secondary : .primary)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              .fill(isPinned ? Color.clear : Color.backgroundTertiary)
          )
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, Spacing.md)

      ScrollView(.horizontal) {
        HStack(spacing: Spacing.sm) {
          ContextGaugeCompact(stats: usageStats)

          if usageStats.estimatedCostUSD > 0 {
            Text(usageStats.formattedCost)
              .font(.system(size: TypeScale.code, weight: .semibold, design: .monospaced))
              .foregroundStyle(.primary.opacity(OpacityTier.vivid))
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xs)
              .background(Color.backgroundTertiary, in: Capsule())
          }

          if let branch = obs.branch, !branch.isEmpty {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: TypeScale.caption, weight: .semibold))
              Text(compactBranchLabel(branch))
                .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(Color.gitBranch)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.backgroundTertiary, in: Capsule())
          }

          if let lastActivity = obs.lastActivityAt {
            Text(lastActivity, style: .relative)
              .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xs)
              .background(Color.backgroundTertiary, in: Capsule())
          }
        }
        .padding(.horizontal, Spacing.md)
      }
      .scrollIndicators(.hidden)
    }
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundSecondary)
    .animation(Motion.standard, value: isPinned)
    .animation(Motion.standard, value: unreadCount)
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
    let fileCount = diffFileCount
    return Button {
      let nextLayout = SessionDetailLayoutPlanner.nextLayout(
        currentLayout: layoutConfig,
        intent: .revealReviewSplit
      )
      withAnimation(Motion.gentle) {
        layoutConfig = nextLayout
        showDiffBanner = false
      }
    } label: {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "doc.badge.plus")
          .font(.system(size: TypeScale.body, weight: .medium))
        Text("\(fileCount) file\(fileCount == 1 ? "" : "s") changed — Review Diffs")
          .font(.system(size: TypeScale.body, weight: .medium))
        Image(systemName: "arrow.right")
          .font(.system(size: TypeScale.micro, weight: .bold))
      }
      .foregroundStyle(Color.accent)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .background(Color.accent.opacity(OpacityTier.subtle), in: Capsule())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundSecondary)
    .transition(.move(edge: .top).combined(with: .opacity))
  }

  private var diffFileCount: Int {
    // Build cumulative diff from all turn snapshots + current live diff
    var parts: [String] = []
    for td in obs.turnDiffs {
      parts.append(td.diff)
    }
    if let current = obs.diff, !current.isEmpty {
      if obs.turnDiffs.last?.diff != current {
        parts.append(current)
      }
    }
    let combined = parts.joined(separator: "\n")
    guard !combined.isEmpty else { return 0 }
    return DiffModel.parse(unifiedDiff: combined).files.count
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
    let bannerState = sessionDetailWorktreeCleanupState

    return VStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.accent)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Worktree: \(bannerState?.branchName ?? "unknown")")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
          Text("This session used a worktree that may still be on disk.")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textSecondary)
        }
        Spacer()
      }

      if let error = worktreeCleanupError {
        Text(error)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.statusPermission)
      }

      HStack(spacing: Spacing.md) {
        Toggle("Delete branch too", isOn: $deleteBranchOnCleanup)
        #if os(macOS)
          .toggleStyle(.checkbox)
        #endif
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textSecondary)

        Spacer()

        Button("Keep") {
          withAnimation(Motion.gentle) {
            worktreeCleanupDismissed = true
          }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textSecondary)
        .font(.system(size: TypeScale.body, weight: .medium))

        Button {
          cleanUpWorktree()
        } label: {
          if isCleaningUpWorktree {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Clean Up")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accent)
        .font(.system(size: TypeScale.body, weight: .medium))
        .disabled(!(bannerState?.canCleanUp ?? false))
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundSecondary)
    .transition(.move(edge: .top).combined(with: .opacity))
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

  private func compactBranchLabel(_ branch: String) -> String {
    let maxLength = 14
    guard branch.count > maxLength else { return branch }
    return String(branch.prefix(maxLength - 1)) + "…"
  }

  private func compactProjectPath(_ path: String) -> String {
    // Show last two path components: "parent/project"
    let components = path.split(separator: "/")
    if components.count >= 2 {
      return components.suffix(2).joined(separator: "/")
    }
    return path
  }

  private var usageStats: TranscriptUsageStats {
    var stats = TranscriptUsageStats()
    stats.model = obs.model

    let input = obs.inputTokens ?? 0
    let output = obs.outputTokens ?? 0
    let cached = obs.cachedTokens ?? 0
    let context = obs.effectiveContextInputTokens
    let hasServerUsage = input > 0 || output > 0 || cached > 0 || context > 0

    if hasServerUsage {
      stats.inputTokens = input
      stats.outputTokens = output
      stats.cacheReadTokens = cached
      stats.contextUsed = context
    } else {
      stats.outputTokens = max(obs.totalTokens, 0)
    }

    return stats
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
