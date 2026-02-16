//
//  SessionDetailView.swift
//  OrbitDock
//

import OSLog
import SwiftUI

struct SessionDetailView: View {
  @Environment(ServerAppState.self) private var serverState
  let session: Session
  let onTogglePanel: () -> Void
  let onOpenSwitcher: () -> Void
  let onGoToDashboard: () -> Void

  @State private var terminalActionFailed = false
  @State private var copiedResume = false

  // Chat scroll state
  @State private var isPinned = true
  @State private var unreadCount = 0
  @State private var scrollToBottomTrigger = 0

  // Turn sidebar state - starts closed, user must trigger it
  @State private var showTurnSidebar = false
  @State private var showApprovalHistory = false

  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OrbitDock", category: "session-detail")
  @State private var railPreset: RailPreset = .planFocused
  @State private var selectedSkills: Set<String> = []

  // Layout state for review canvas
  @State private var layoutConfig: LayoutConfiguration = .conversationOnly
  @State private var showDiffBanner = false
  @State private var reviewFileId: String?
  @State private var navigateToComment: ServerReviewComment?
  @State private var selectedCommentIds: Set<String> = []

  var body: some View {
    VStack(spacing: 0) {
      // Compact header
      HeaderView(
        session: session,
        currentTool: currentTool,
        onTogglePanel: onTogglePanel,
        onOpenSwitcher: onOpenSwitcher,
        onFocusTerminal: { openInITerm() },
        onGoToDashboard: onGoToDashboard,
        onEndSession: session.isDirect ? { endDirectSession() } : nil,
        showTurnSidebar: session.isDirect ? $showTurnSidebar : nil,
        hasSidebarContent: hasSidebarContent,
        layoutConfig: session.isDirect ? $layoutConfig : nil
      )

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Diff-available banner
      if showDiffBanner, layoutConfig == .conversationOnly {
        diffAvailableBanner
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
            sessionId: session.id,
            projectPath: session.projectPath,
            isSessionActive: session.isActive,
            compact: layoutConfig == .split,
            navigateToFileId: $reviewFileId,
            onDismiss: {
              withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                layoutConfig = .conversationOnly
              }
            },
            selectedCommentIds: $selectedCommentIds,
            navigateToComment: $navigateToComment
          )
          .frame(maxWidth: .infinity)
        }

        // Turn sidebar - plan + diff + servers + skills (Codex direct only)
        if session.isDirect, showTurnSidebar {
          Divider()
            .foregroundStyle(Color.panelBorder)

          CodexTurnSidebar(
            sessionId: session.id,
            onClose: {
              withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                showTurnSidebar = false
              }
            },
            railPreset: $railPreset,
            selectedSkills: $selectedSkills,
            selectedCommentIds: $selectedCommentIds,
            onOpenReview: {
              withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                layoutConfig = .split
              }
            },
            onNavigateToSession: { id in
              NotificationCenter.default.post(
                name: .selectSession,
                object: nil,
                userInfo: ["sessionId": id]
              )
            },
            onNavigateToComment: { comment in
              navigateToComment = comment
              withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                if layoutConfig == .conversationOnly {
                  layoutConfig = .split
                }
              }
            },
            onSendReview: {
              sendReviewToModel()
            }
          )
          .frame(width: 320)
          .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showTurnSidebar)

      // Action bar (unified instrument panel for Codex, simpler bar for Claude)
      if session.isDirect {
        InstrumentPanel(
          session: session,
          selectedSkills: $selectedSkills,
          isPinned: $isPinned,
          unreadCount: $unreadCount,
          scrollToBottomTrigger: $scrollToBottomTrigger,
          showApprovalHistory: $showApprovalHistory,
          onOpenSkills: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              showTurnSidebar = true
            }
          }
        )
      } else {
        actionBar
      }
    }
    .background(Color.backgroundPrimary)
    .onAppear {
      if shouldSubscribeToServerSession {
        serverState.subscribeToSession(session.id)
        if session.isDirect {
          serverState.loadApprovalHistory(sessionId: session.id)
          serverState.loadGlobalApprovalHistory()
          serverState.listMcpTools(sessionId: session.id)
          serverState.listSkills(sessionId: session.id)
          serverState.listReviewComments(sessionId: session.id)
        }
      }
    }
    .onDisappear {
      if shouldSubscribeToServerSession {
        serverState.unsubscribeFromSession(session.id)
      }
    }
    .onChange(of: session.id) { oldId, newId in
      // Unsubscribe from old session if it was server-managed
      if serverState.isServerSession(oldId) {
        serverState.unsubscribeFromSession(oldId)
      }
      if shouldSubscribeToServerSession {
        serverState.subscribeToSession(newId)
        if session.isDirect {
          serverState.loadApprovalHistory(sessionId: newId)
          serverState.loadGlobalApprovalHistory()
          serverState.listMcpTools(sessionId: newId)
          serverState.listSkills(sessionId: newId)
          serverState.listReviewComments(sessionId: newId)
        }
      }
      // Reset state for new session
      isPinned = true
      unreadCount = 0
      selectedSkills = []
      railPreset = .planFocused
      layoutConfig = .conversationOnly
      showDiffBanner = false
      navigateToComment = nil
    }
    .alert("Terminal Not Found", isPresented: $terminalActionFailed) {
      Button("Open New") { TerminalService.shared.focusSession(session) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Couldn't find the terminal. Open a new iTerm window to resume?")
    }
    // Keyboard shortcuts for rail presets + rail toggle (Cmd+Option to avoid macOS screenshot conflicts)
    .onKeyPress(phases: .down) { keyPress in
      guard keyPress.modifiers == [.command, .option] else { return .ignored }

      switch keyPress.key {
        case KeyEquivalent("1"):
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            railPreset = .planFocused
            showTurnSidebar = true
          }
          return .handled

        case KeyEquivalent("2"):
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            railPreset = .reviewFocused
            showTurnSidebar = true
          }
          return .handled

        case KeyEquivalent("3"):
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            railPreset = .triage
            showTurnSidebar = true
          }
          return .handled

        case KeyEquivalent("r"):
          withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            showTurnSidebar.toggle()
          }
          return .handled

        default:
          return .ignored
      }
    }
    // Layout keyboard shortcuts
    .onKeyPress(phases: .down) { keyPress in
      guard session.isDirect else { return .ignored }

      // Cmd+D: Toggle conversation ↔ split
      if keyPress.modifiers == .command, keyPress.key == KeyEquivalent("d") {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          layoutConfig = layoutConfig == .conversationOnly ? .split : .conversationOnly
        }
        return .handled
      }

      // Cmd+Shift+D: Review only
      if keyPress.modifiers == [.command, .shift], keyPress.key == KeyEquivalent("d") {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          layoutConfig = .reviewOnly
        }
        return .handled
      }

      // Note: Escape intentionally not used here — ReviewCanvas uses q to close,
      // and Escape is reserved for canceling mark/composer within the canvas.

      return .ignored
    }
    // Diff-available banner trigger
    .onChange(of: serverState.session(session.id).diff) { oldDiff, newDiff in
      guard session.isDirect else { return }
      if oldDiff == nil, newDiff != nil, layoutConfig == .conversationOnly {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
          showDiffBanner = true
        }
        // Auto-dismiss after 8 seconds
        Task {
          try? await Task.sleep(for: .seconds(8))
          await MainActor.run {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              showDiffBanner = false
            }
          }
        }
      }
    }
  }

  // MARK: - Action Bar

  private var actionBar: some View {
    HStack(spacing: Spacing.lg) {
      // Focus/Resume
      Button {
        openInITerm()
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: session.isActive ? "arrow.up.forward.app" : "terminal")
            .font(.system(size: TypeScale.code, weight: .medium))
          Text(session.isActive ? "Focus" : "Resume")
            .font(.system(size: TypeScale.code, weight: .medium))
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .foregroundStyle(.primary)
      }
      .buttonStyle(.plain)
      .keyboardShortcut("t", modifiers: .command)
      .help(session.isActive ? "Focus terminal (⌘T)" : "Resume in iTerm (⌘T)")

      // Secondary actions
      HStack(spacing: Spacing.xxs) {
        Button {
          copyResumeCommand()
        } label: {
          Image(systemName: copiedResume ? "checkmark" : "doc.on.doc")
            .font(.system(size: TypeScale.code, weight: .medium))
            .frame(width: 32, height: 32)
            .foregroundStyle(copiedResume ? Color.statusSuccess : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy resume command")

        Button {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
        } label: {
          Image(systemName: "folder")
            .font(.system(size: TypeScale.code, weight: .medium))
            .frame(width: 32, height: 32)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open in Finder")
      }
      .padding(Spacing.xxs)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))

      // Context stats
      HStack(spacing: Spacing.md) {
        ContextGaugeCompact(stats: usageStats)

        if usageStats.estimatedCostUSD > 0 {
          Text(usageStats.formattedCost)
            .font(.system(size: TypeScale.code, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary.opacity(OpacityTier.vivid))
        }
      }

      Spacer()

      // Right: Chat scroll + timestamp
      HStack(spacing: Spacing.lg) {
        // New messages button (only when paused with unread)
        if !isPinned, unreadCount > 0 {
          Button {
            isPinned = true
            unreadCount = 0
            scrollToBottomTrigger += 1
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "arrow.down")
                .font(.system(size: TypeScale.caption, weight: .bold))
              Text("\(unreadCount) new")
                .font(.system(size: TypeScale.code, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.accent, in: Capsule())
          }
          .buttonStyle(.plain)
          .transition(.scale.combined(with: .opacity))
        }

        // Scroll toggle
        Button {
          isPinned.toggle()
          if isPinned {
            unreadCount = 0
            scrollToBottomTrigger += 1
          }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: isPinned ? "arrow.down.to.line" : "pause")
              .font(.system(size: TypeScale.body, weight: .medium))
            Text(isPinned ? "Following" : "Paused")
              .font(.system(size: TypeScale.code, weight: .medium))
          }
          .foregroundStyle(isPinned ? .secondary : .primary)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
          .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
              .fill(isPinned ? Color.clear : Color.backgroundTertiary)
          )
        }
        .buttonStyle(.plain)

        // Last activity timestamp
        if let lastActivity = session.lastActivityAt {
          Text(lastActivity, style: .relative)
            .font(.system(size: TypeScale.body, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
      }
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isPinned)
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: unreadCount)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .background(Color.backgroundSecondary)
  }

  // MARK: - Conversation Content

  private var conversationContent: some View {
    ConversationView(
      transcriptPath: session.transcriptPath,
      sessionId: session.id,
      isSessionActive: session.isActive,
      workStatus: session.workStatus,
      currentTool: currentTool,
      pendingToolName: session.pendingToolName,
      pendingToolInput: session.pendingToolInput,
      provider: session.provider,
      model: session.model,
      onNavigateToReviewFile: { filePath, lineNumber in
        // Navigate to the file in the review canvas and jump to the line
        reviewFileId = filePath
        // Create a synthetic comment to navigate to the specific line
        navigateToComment = ServerReviewComment(
          id: "nav-\(filePath)-\(lineNumber)",
          sessionId: session.id,
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          if layoutConfig == .conversationOnly {
            layoutConfig = .split
          }
        }
      },
      isPinned: $isPinned,
      unreadCount: $unreadCount,
      scrollToBottomTrigger: $scrollToBottomTrigger
    )
    .environment(\.openFileInReview, session.isDirect ? { filePath in
      // Extract the relative file path (strip project path prefix if present)
      let relative = filePath.hasPrefix(session.projectPath)
        ? String(filePath.dropFirst(session.projectPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        : filePath
      reviewFileId = relative
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
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
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
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
    .padding(.vertical, 4)
    .background(Color.backgroundSecondary)
    .transition(.move(edge: .top).combined(with: .opacity))
  }

  private var diffFileCount: Int {
    let obs = serverState.session(session.id)
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

  // MARK: - Turn Sidebar Helpers

  /// Whether any sidebar tab has content (for header badge indicator)
  private var hasSidebarContent: Bool {
    guard session.isDirect else { return false }
    let obs = serverState.session(session.id)
    let hasPlan = obs.getPlanSteps() != nil
    let hasDiff = obs.diff != nil
    let hasMcp = obs.hasMcpData
    let hasSkills = !obs.skills.isEmpty
    return hasPlan || hasDiff || hasMcp || hasSkills
  }

  private var currentTool: String? {
    session.lastTool
  }

  private var usageStats: TranscriptUsageStats {
    var stats = TranscriptUsageStats()
    stats.model = session.model

    if session.provider == .codex {
      stats.inputTokens = session.codexInputTokens ?? 0
      stats.outputTokens = session.codexOutputTokens ?? 0
      stats.cacheReadTokens = session.codexCachedTokens ?? 0
      stats.contextUsed = session.codexContextWindow ?? 0
    } else {
      stats.outputTokens = max(session.totalTokens, 0)
    }

    return stats
  }

  // MARK: - Helpers

  private var shouldSubscribeToServerSession: Bool {
    // Any server-managed session (direct or passive) needs snapshot/message subscription.
    // Restricting this to direct sessions causes passive Codex sessions to render "No messages yet".
    serverState.isServerSession(session.id)
  }

  private func copyResumeCommand() {
    let command = "claude --resume \(session.id)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    copiedResume = true

    // Reset after visual feedback
    Task {
      try? await Task.sleep(for: .seconds(2))
      await MainActor.run {
        copiedResume = false
      }
    }
  }

  private func openInITerm() {
    logger
      .info(
        "focus terminal clicked session=\(session.id, privacy: .public) provider=\(String(describing: session.provider), privacy: .public)"
      )
    TerminalService.shared.focusSession(session)
  }

  private func endDirectSession() {
    serverState.endSession(session.id)
  }

  // MARK: - Send Review

  /// Format review comments and send as a structured message to the model.
  /// Uses selected comments if any, otherwise all open. Includes diff content
  /// and embeds comment IDs for transcript traceability.
  private func sendReviewToModel() {
    let obs = serverState.session(session.id)
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

    serverState.sendMessage(sessionId: session.id, content: message)

    // Resolve sent comments
    for comment in commentsToSend {
      serverState.updateReviewComment(
        commentId: comment.id,
        body: nil,
        tag: nil,
        status: .resolved
      )
    }

    // Clear selection after send
    selectedCommentIds.removeAll()
  }
}

#Preview {
  SessionDetailView(
    session: Session(
      id: "preview-123",
      projectPath: "/Users/test/project",
      model: "opus",
      status: .active,
      workStatus: .working
    ),
    onTogglePanel: {},
    onOpenSwitcher: {},
    onGoToDashboard: {}
  )
  .environment(ServerAppState())
  .environment(AttentionService())
  .frame(width: 800, height: 600)
}
