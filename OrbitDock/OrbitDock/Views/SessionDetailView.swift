//
//  SessionDetailView.swift
//  OrbitDock
//

import OSLog
import SwiftUI

struct SessionDetailView: View {
  @Environment(SessionStore.self) private var serverState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(AppRouter.self) private var router
  let sessionId: String
  let endpointId: UUID

  private var obs: SessionObservable {
    serverState.session(sessionId)
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
            if layoutConfig == .conversationOnly {
              layoutConfig = .split
            }
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
                layoutConfig = .conversationOnly
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
          isPinned: $isPinned,
          unreadCount: $unreadCount,
          scrollToBottomTrigger: $scrollToBottomTrigger
        )
      } else {
        if obs.canTakeOver, !obs.needsApprovalOverlay {
          TakeOverInputBar {
            Task { try? await serverState.takeoverSession(sessionId) }
          }
        }
        actionBar
      }
    }
    .background(Color.backgroundPrimary)
    .onAppear {
      if shouldSubscribeToServerSession {
        // Let SessionStore choose the best recovery path: retained state, cached restore,
        // or full-history recovery when the detail view needs to rebuild after being away.
        serverState.subscribeToSession(sessionId, recoveryGoal: .completeHistory)
        serverState.setSessionAutoMarkRead(sessionId, enabled: isPinned)
        if obs.isDirect {
          Task {
            if let resp = try? await serverState.apiClient.listApprovals(sessionId: sessionId) {
              serverState.session(sessionId).approvalHistory = resp.approvals
            }
          }
        }
      }
    }
    .onDisappear {
      if shouldSubscribeToServerSession {
        serverState.setSessionAutoMarkRead(sessionId, enabled: false)
        serverState.unsubscribeFromSession(sessionId)
      }
    }
    .onChange(of: isPinned) { _, pinned in
      guard shouldSubscribeToServerSession else { return }
      serverState.setSessionAutoMarkRead(sessionId, enabled: pinned)
    }
    // Layout keyboard shortcuts
    .onKeyPress(phases: .down) { keyPress in
      guard obs.isDirect else { return .ignored }

      // Cmd+D: Toggle conversation ↔ split
      if keyPress.modifiers == .command, keyPress.key == KeyEquivalent("d") {
        withAnimation(Motion.gentle) {
          layoutConfig = layoutConfig == .conversationOnly ? .split : .conversationOnly
        }
        return .handled
      }

      // Cmd+Shift+D: Review only
      if keyPress.modifiers == [.command, .shift], keyPress.key == KeyEquivalent("d") {
        withAnimation(Motion.gentle) {
          layoutConfig = .reviewOnly
        }
        return .handled
      }

      // Note: Escape intentionally not used here — ReviewCanvas uses q to close,
      // and Escape is reserved for canceling mark/composer within the canvas.

      return .ignored
    }
    // Diff-available banner trigger
    .onChange(of: serverState.session(sessionId).diff) { oldDiff, newDiff in
      guard obs.isDirect else { return }
      if oldDiff == nil, newDiff != nil, layoutConfig == .conversationOnly {
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
        // Navigate to the file in the review canvas and jump to the line
        reviewFileId = filePath
        // Create a synthetic comment to navigate to the specific line
        navigateToComment = ServerReviewComment(
          id: "nav-\(filePath)-\(lineNumber)",
          sessionId: sessionId,
          turnId: nil,
          filePath: filePath,
          lineStart: UInt32(lineNumber),
          lineEnd: nil,
          body: "",
          tag: nil,
          status: .resolved,
          createdAt: "",
          updatedAt: nil
        )
        withAnimation(Motion.gentle) {
          if layoutConfig == .conversationOnly {
            layoutConfig = .split
          }
        }
      },
      isPinned: $isPinned,
      unreadCount: $unreadCount,
      scrollToBottomTrigger: $scrollToBottomTrigger
    )
    .environment(\.openFileInReview, obs.isDirect ? { filePath in
      // Extract the relative file path (strip project path prefix if present)
      let relative = filePath.hasPrefix(obs.projectPath)
        ? String(filePath.dropFirst(obs.projectPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        : filePath
      reviewFileId = relative
      withAnimation(Motion.gentle) {
        if layoutConfig == .conversationOnly {
          layoutConfig = .split
        }
      }
    } : nil)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Diff Available Banner

  private var diffAvailableBanner: some View {
    let fileCount = diffFileCount
    return Button {
      withAnimation(Motion.gentle) {
        layoutConfig = .split
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
    obs.status == .ended && obs.isWorktree && !worktreeCleanupDismissed
  }

  private var worktreeForSession: ServerWorktreeSummary? {
    if let wtId = obs.worktreeId {
      return serverState.worktreesByRepo.values.flatMap { $0 }.first { $0.id == wtId }
    }
    return serverState.worktreesByRepo.values.flatMap { $0 }.first { $0.worktreePath == obs.projectPath }
  }

  private var worktreeCleanupBanner: some View {
    let wt = worktreeForSession
    let branchName = wt?.branch ?? obs.branch ?? "unknown"

    return VStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.accent)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Worktree: \(branchName)")
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
        .disabled(isCleaningUpWorktree || wt == nil)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.backgroundSecondary)
    .transition(.move(edge: .top).combined(with: .opacity))
  }

  private func cleanUpWorktree() {
    guard let wt = worktreeForSession else { return }
    isCleaningUpWorktree = true
    worktreeCleanupError = nil

    Task {
      do {
        try await serverState.apiClient.removeWorktree(
          worktreeId: wt.id,
          force: true,
          deleteBranch: deleteBranchOnCleanup
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
    Task { try? await serverState.endSession(sessionId) }
  }

  // MARK: - Send Review

  /// Format review comments and send as a structured message to the model.
  /// Uses selected comments if any, otherwise all open. Includes diff content
  /// and embeds comment IDs for transcript traceability.
  private func sendReviewToModel() {
    let openComments = obs.reviewComments.filter { $0.status == .open }
    guard !openComments.isEmpty else { return }

    // Use selected comments if any, otherwise all open
    let commentsToSend: [ServerReviewComment]
    if !selectedCommentIds.isEmpty {
      commentsToSend = openComments.filter { selectedCommentIds.contains($0.id) }
      guard !commentsToSend.isEmpty else { return }
    } else {
      commentsToSend = openComments
    }

    // Build diff model for code extraction
    let diffModel: DiffModel? = {
      var parts: [String] = []
      for td in obs.turnDiffs {
        parts.append(td.diff)
      }
      if let current = obs.diff, !current.isEmpty {
        if obs.turnDiffs.last?.diff != current { parts.append(current) }
      }
      let combined = parts.joined(separator: "\n")
      return combined.isEmpty ? nil : DiffModel.parse(unifiedDiff: combined)
    }()

    // Group by file path, preserving order of first appearance
    var fileOrder: [String] = []
    var grouped: [String: [ServerReviewComment]] = [:]
    for comment in commentsToSend {
      if grouped[comment.filePath] == nil {
        fileOrder.append(comment.filePath)
      }
      grouped[comment.filePath, default: []].append(comment)
    }

    var lines: [String] = ["## Code Review Feedback", ""]

    for filePath in fileOrder {
      let comments = grouped[filePath] ?? []
      let ext = filePath.components(separatedBy: ".").last ?? ""
      lines.append("### \(filePath)")

      for comment in comments.sorted(by: { $0.lineStart < $1.lineStart }) {
        let lineRef = if let end = comment.lineEnd, end != comment.lineStart {
          "Lines \(comment.lineStart)–\(end)"
        } else {
          "Line \(comment.lineStart)"
        }

        let tagStr = comment.tag.map { " [\($0.rawValue)]" } ?? ""
        lines.append("")
        lines.append("**\(lineRef)**\(tagStr):")

        // Include actual diff content
        if let file = diffModel?.files.first(where: { $0.newPath == filePath }) {
          let start = Int(comment.lineStart)
          let end = comment.lineEnd.map { Int($0) } ?? start
          var extracted: [String] = []
          for hunk in file.hunks {
            for line in hunk.lines {
              guard let newNum = line.newLineNum else {
                if !extracted.isEmpty, line.type == .removed {
                  extracted.append("\(line.prefix)\(line.content)")
                }
                continue
              }
              if newNum >= start, newNum <= end {
                extracted.append("\(line.prefix)\(line.content)")
              }
            }
          }
          if !extracted.isEmpty {
            lines.append("```\(ext)")
            lines.append(extracted.joined(separator: "\n"))
            lines.append("```")
          }
        }

        lines.append("> \(comment.body)")
      }

      lines.append("")
    }

    // Embed comment IDs for transcript traceability
    let ids = commentsToSend.map(\.id).joined(separator: ",")
    lines.append("<!-- review-comment-ids: \(ids) -->")

    let message = lines.joined(separator: "\n")

    Task {
      try? await serverState.sendMessage(sessionId: sessionId, content: message)

      // Resolve sent comments
      for comment in commentsToSend {
        try? await serverState.apiClient.updateReviewComment(
          commentId: comment.id,
          body: APIClient.UpdateReviewCommentRequest(status: .resolved)
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
