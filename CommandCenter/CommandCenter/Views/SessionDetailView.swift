//
//  SessionDetailView.swift
//  OrbitDock
//

import SwiftUI
import OSLog

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
        onEndSession: session.isDirectCodex ? { endCodexSession() } : nil,
        showTurnSidebar: session.isDirectCodex ? $showTurnSidebar : nil,
        hasSidebarContent: hasSidebarContent,
        layoutConfig: session.isDirectCodex ? $layoutConfig : nil
      )

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Diff-available banner
      if showDiffBanner, layoutConfig == .conversationOnly {
        diffAvailableBanner
      }

      // Main content area with layout switch
      HStack(spacing: 0) {
        // Center zone — layout-dependent
        Group {
          switch layoutConfig {
          case .conversationOnly:
            conversationContent

          case .reviewOnly:
            ReviewCanvas(
              sessionId: session.id,
              projectPath: session.projectPath,
              isSessionActive: session.isActive,
              navigateToFileId: $reviewFileId,
              onDismiss: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                  layoutConfig = .conversationOnly
                }
              }
            )

          case .split:
            HStack(spacing: 0) {
              conversationContent
                .frame(maxWidth: .infinity)

              Divider()
                .foregroundStyle(Color.panelBorder)

              ReviewCanvas(
                sessionId: session.id,
                projectPath: session.projectPath,
                isSessionActive: session.isActive,
                compact: true,
                navigateToFileId: $reviewFileId,
                onDismiss: {
                  withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    layoutConfig = .conversationOnly
                  }
                }
              )
              .frame(maxWidth: .infinity)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: layoutConfig)

        // Turn sidebar - plan + diff + servers + skills (Codex direct only)
        if session.isDirectCodex, showTurnSidebar {
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
            }
          )
          .frame(width: 320)
          .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showTurnSidebar)

      // Codex direct: Approval or question UI when needed
      if session.isDirectCodex {
        if session.canApprove {
          CodexApprovalView(session: session)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else if session.canAnswer {
          CodexQuestionView(session: session)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }

        if showApprovalHistory {
          CodexApprovalHistoryView(sessionId: session.id)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
      }

      // Action bar (or input bar for direct Codex)
      if session.isDirectCodex {
        codexActionBar
      } else {
        actionBar
      }
    }
    .background(Color.backgroundPrimary)
    .onAppear {
      if shouldSubscribeToServerSession {
        serverState.subscribeToSession(session.id)
        if session.isDirectCodex {
          serverState.loadApprovalHistory(sessionId: session.id)
          serverState.loadGlobalApprovalHistory()
          serverState.listMcpTools(sessionId: session.id)
          serverState.listSkills(sessionId: session.id)
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
        if session.isDirectCodex {
          serverState.loadApprovalHistory(sessionId: newId)
          serverState.loadGlobalApprovalHistory()
          serverState.listMcpTools(sessionId: newId)
          serverState.listSkills(sessionId: newId)
        }
      }
      // Reset state for new session
      isPinned = true
      unreadCount = 0
      selectedSkills = []
      railPreset = .planFocused
      layoutConfig = .conversationOnly
      showDiffBanner = false
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
      guard session.isDirectCodex else { return .ignored }

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

      // Escape: Return to conversation from review/split
      if keyPress.key == .escape, layoutConfig != .conversationOnly {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
          layoutConfig = .conversationOnly
        }
        return .handled
      }

      return .ignored
    }
    // Diff-available banner trigger
    .onChange(of: serverState.session(session.id).diff) { oldDiff, newDiff in
      guard session.isDirectCodex else { return }
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
    HStack(spacing: 16) {
      // Focus/Resume
      Button {
        openInITerm()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: session.isActive ? "arrow.up.forward.app" : "terminal")
            .font(.system(size: 12, weight: .medium))
          Text(session.isActive ? "Focus" : "Resume")
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(.primary)
      }
      .buttonStyle(.plain)
      .keyboardShortcut("t", modifiers: .command)
      .help(session.isActive ? "Focus terminal (⌘T)" : "Resume in iTerm (⌘T)")

      // Secondary actions
      HStack(spacing: 2) {
        Button {
          copyResumeCommand()
        } label: {
          Image(systemName: copiedResume ? "checkmark" : "doc.on.doc")
            .font(.system(size: 12, weight: .medium))
            .frame(width: 32, height: 32)
            .foregroundStyle(copiedResume ? Color.statusSuccess : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy resume command")

        Button {
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
        } label: {
          Image(systemName: "folder")
            .font(.system(size: 12, weight: .medium))
            .frame(width: 32, height: 32)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open in Finder")
      }
      .padding(2)
      .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      // Context stats
      HStack(spacing: 12) {
        ContextGaugeCompact(stats: usageStats)

        if usageStats.estimatedCostUSD > 0 {
          Text(usageStats.formattedCost)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.8))
        }
      }

      Spacer()

      // Right: Chat scroll + timestamp
      HStack(spacing: 16) {
        // New messages button (only when paused with unread)
        if !isPinned, unreadCount > 0 {
          Button {
            isPinned = true
            unreadCount = 0
            scrollToBottomTrigger += 1
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))
              Text("\(unreadCount) new")
                .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
              .font(.system(size: 11, weight: .medium))
            Text(isPinned ? "Following" : "Paused")
              .font(.system(size: 12, weight: .medium))
          }
          .foregroundStyle(isPinned ? .secondary : .primary)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(isPinned ? Color.clear : Color.backgroundTertiary)
          )
        }
        .buttonStyle(.plain)

        // Last activity timestamp
        if let lastActivity = session.lastActivityAt {
          Text(lastActivity, style: .relative)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
      }
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isPinned)
      .animation(.spring(response: 0.25, dampingFraction: 0.8), value: unreadCount)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color.backgroundSecondary)
  }

  // MARK: - Codex Direct Action Bar

  private var codexActionBar: some View {
    VStack(spacing: 0) {
      if !session.isActive {
        // Resume button when session is ended
        HStack {
          Button {
            serverState.resumeSession(session.id)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .medium))
              Text("Resume")
                .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(Color.accent)
          }
          .buttonStyle(.plain)

          Spacer()

          if let lastActivity = session.lastActivityAt {
            Text(lastActivity, style: .relative)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.tertiary)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.backgroundSecondary)
      } else {
        // Input bar when waiting for input
        if session.workStatus == .waiting || session.workStatus == .unknown || session.workStatus == .working {
          CodexInputBar(
            sessionId: session.id,
            selectedSkills: $selectedSkills,
            onOpenSkills: {
              withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                showTurnSidebar = true
              }
            }
          )
        }

        // Status bar
        HStack(spacing: 16) {
          // Interrupt button when working
          if session.workStatus == .working {
            CodexInterruptButton(sessionId: session.id)
          }

          // Token usage for this session
          if session.hasTokenUsage {
            CodexTokenBadge(session: session)

            // Compact context button (next to token badge)
            Button {
              serverState.compactContext(sessionId: session.id)
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                  .font(.system(size: 11, weight: .medium))
                Text("Compact")
                  .font(.system(size: 11, weight: .medium))
              }
              .foregroundStyle(.secondary)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Summarize conversation to free context window")
          }

          // Autonomy level pill
          AutonomyPill(sessionId: session.id)

          // Undo last turn button
          Button {
            serverState.undoLastTurn(sessionId: session.id)
          } label: {
            HStack(spacing: 4) {
              if serverState.session(session.id).undoInProgress {
                ProgressView()
                  .controlSize(.mini)
              } else {
                Image(systemName: "arrow.uturn.backward")
                  .font(.system(size: 11, weight: .medium))
              }
              Text("Undo")
                .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(serverState.session(session.id).undoInProgress)
          .help("Undo last turn (reverts filesystem changes)")

          // Fork conversation button
          Button {
            serverState.forkSession(sessionId: session.id)
          } label: {
            HStack(spacing: 4) {
              if serverState.session(session.id).forkInProgress {
                ProgressView()
                  .controlSize(.mini)
              } else {
                Image(systemName: "arrow.triangle.branch")
                  .font(.system(size: 11, weight: .medium))
              }
              Text("Fork")
                .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(serverState.session(session.id).forkInProgress)
          .help("Fork conversation (creates a new session with full history)")

          Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              showApprovalHistory.toggle()
            }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "checklist")
                .font(.system(size: 11, weight: .medium))
              Text("Approvals")
                .font(.system(size: 11, weight: .medium))
              if approvalHistoryCount > 0 {
                Text("\(approvalHistoryCount)")
                  .font(.system(size: 10, weight: .bold))
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(Color.accent.opacity(0.18), in: Capsule())
                  .foregroundStyle(Color.accent)
              }
            }
            .foregroundStyle(showApprovalHistory ? Color.accent : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
              showApprovalHistory ? Color.accent.opacity(0.15) : Color.surfaceHover,
              in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
          }
          .buttonStyle(.plain)

          Spacer()

          // Chat scroll controls + timestamp
          HStack(spacing: 16) {
            // New messages button
            if !isPinned, unreadCount > 0 {
              Button {
                isPinned = true
                unreadCount = 0
                scrollToBottomTrigger += 1
              } label: {
                HStack(spacing: 5) {
                  Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                  Text("\(unreadCount) new")
                    .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accent, in: Capsule())
              }
              .buttonStyle(.plain)
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
                  .font(.system(size: 11, weight: .medium))
                Text(isPinned ? "Following" : "Paused")
                  .font(.system(size: 12, weight: .medium))
              }
              .foregroundStyle(isPinned ? .secondary : .primary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(isPinned ? Color.clear : Color.backgroundTertiary)
              )
            }
            .buttonStyle(.plain)

            // Last activity timestamp
            if let lastActivity = session.lastActivityAt {
              Text(lastActivity, style: .relative)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.backgroundSecondary)
      }
    }
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
      isPinned: $isPinned,
      unreadCount: $unreadCount,
      scrollToBottomTrigger: $scrollToBottomTrigger
    )
    .environment(\.openFileInReview, session.isDirectCodex ? { filePath in
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
      HStack(spacing: 6) {
        Image(systemName: "doc.badge.plus")
          .font(.system(size: 11, weight: .medium))
        Text("\(fileCount) file\(fileCount == 1 ? "" : "s") changed — Review Diffs")
          .font(.system(size: 11, weight: .medium))
        Image(systemName: "arrow.right")
          .font(.system(size: 9, weight: .bold))
      }
      .foregroundStyle(Color.accent)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(Color.accent.opacity(0.1), in: Capsule())
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
    guard session.isDirectCodex else { return false }
    let obs = serverState.session(session.id)
    let hasPlan = obs.getPlanSteps() != nil
    let hasDiff = obs.diff != nil
    let hasMcp = obs.hasMcpData
    let hasSkills = !obs.skills.isEmpty
    return hasPlan || hasDiff || hasMcp || hasSkills
  }

  private var approvalHistoryCount: Int {
    serverState.session(session.id).approvalHistory.count
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
    logger.info("focus terminal clicked session=\(session.id, privacy: .public) provider=\(String(describing: session.provider), privacy: .public)")
    TerminalService.shared.focusSession(session)
  }

  private func endCodexSession() {
    serverState.endSession(session.id)
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
