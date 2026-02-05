//
//  SessionDetailView.swift
//  OrbitDock
//

import Combine
import SwiftUI

struct SessionDetailView: View {
  @Environment(DatabaseManager.self) private var database
  @Environment(CodexDirectSessionManager.self) private var codexManager
  let session: Session
  let onTogglePanel: () -> Void
  let onOpenSwitcher: () -> Void
  let onGoToDashboard: () -> Void

  @State private var usageStats = TranscriptUsageStats()
  @State private var currentTool: String?
  @State private var transcriptSubscription: AnyCancellable?
  @State private var terminalActionFailed = false
  @State private var copiedResume = false

  // Chat scroll state
  @State private var isPinned = true
  @State private var unreadCount = 0
  @State private var scrollToBottomTrigger = 0

  // Diff panel state - starts closed, user must trigger it
  @State private var showDiffPanel = false

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
        onEndSession: session.isDirectCodex ? { endCodexSession() } : nil
      )

      Divider()
        .foregroundStyle(Color.panelBorder)

      // Main content area with optional diff sidebar
      HStack(spacing: 0) {
        // Conversation (hero)
        ConversationView(
          transcriptPath: session.transcriptPath,
          sessionId: session.id,
          isSessionActive: session.isActive,
          workStatus: session.workStatus,
          currentTool: currentTool,
          pendingToolName: session.pendingToolName,
          pendingToolInput: session.pendingToolInput,
          provider: session.provider,
          isPinned: $isPinned,
          unreadCount: $unreadCount,
          scrollToBottomTrigger: $scrollToBottomTrigger
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // Diff sidebar (Codex direct only)
        if session.isDirectCodex,
           showDiffPanel,
           let diff = CodexTurnStateStore.shared.getDiff(sessionId: session.id)
        {
          Divider()
            .foregroundStyle(Color.panelBorder)

          CodexDiffSidebar(diff: diff, onClose: { showDiffPanel = false })
            .frame(width: 350)
        }
      }

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
      loadUsageStats()
      setupSubscription()
    }
    .onDisappear {
      transcriptSubscription?.cancel()
    }
    .onChange(of: session.id) { _, _ in
      transcriptSubscription?.cancel()
      loadUsageStats()
      setupSubscription()
      // Reset scroll state for new session
      isPinned = true
      unreadCount = 0
    }
    .alert("Terminal Not Found", isPresented: $terminalActionFailed) {
      Button("Open New") { TerminalService.shared.focusSession(session) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Couldn't find the terminal. Open a new iTerm window to resume?")
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
      // Input bar when waiting for input
      if session.workStatus == .waiting || session.workStatus == .unknown {
        CodexInputBar(sessionId: session.id)
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
        }

        // Diff panel toggle
        if CodexTurnStateStore.shared.getDiff(sessionId: session.id) != nil {
          Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              showDiffPanel.toggle()
            }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "doc.badge.plus")
                .font(.system(size: 11, weight: .medium))
              Text("Changes")
                .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(showDiffPanel ? Color.accent : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
              showDiffPanel ? Color.accent.opacity(0.15) : Color.surfaceHover,
              in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
          }
          .buttonStyle(.plain)
        }

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

  // MARK: - Helpers

  private func setupSubscription() {
    guard let path = session.transcriptPath else { return }
    let targetSession = session

    transcriptSubscription = EventBus.shared.transcriptUpdated
      .filter { $0 == path }
      .receive(on: DispatchQueue.main)
      .sink { [targetSession] _ in
        guard session.id == targetSession.id else { return }
        loadUsageStats()
      }
  }

  private func loadUsageStats() {
    let targetId = session.id

    DispatchQueue.global(qos: .userInitiated).async {
      if let stats = MessageStore.shared.readStats(sessionId: targetId) {
        let info = MessageStore.shared.readSessionInfo(sessionId: targetId)

        DispatchQueue.main.async {
          guard session.id == targetId else { return }
          usageStats = stats
          currentTool = info.lastTool
        }
      }
    }
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
    TerminalService.shared.focusSession(session)
  }

  private func endCodexSession() {
    Task {
      do {
        try await codexManager.endSession(session.id)
      } catch {
        print("[Codex] Failed to end session: \(error)")
        // Fall back to just ending in database
        database.endSession(sessionId: session.id)
      }
    }
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
  .environment(DatabaseManager.shared)
  .environment(CodexDirectSessionManager())
  .frame(width: 800, height: 600)
}
