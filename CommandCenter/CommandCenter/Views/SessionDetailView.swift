//
//  SessionDetailView.swift
//  OrbitDock
//

import SwiftUI
import Combine

struct SessionDetailView: View {
    @Environment(DatabaseManager.self) private var database
    let session: Session
    let onTogglePanel: () -> Void
    let onOpenSwitcher: () -> Void
    let onGoToDashboard: () -> Void

    @State private var usageStats = TranscriptUsageStats()
    @State private var currentTool: String?
    @State private var transcriptSubscription: AnyCancellable?
    @State private var terminalActionFailed = false
    @State private var copiedResume = false
    @State private var workstream: Workstream?
    @State private var showingWorkstreamDetail = false

    // Chat scroll state
    @State private var isPinned = true
    @State private var unreadCount = 0
    @State private var scrollToBottomTrigger = 0

    var body: some View {
        VStack(spacing: 0) {
            // Compact header with integrated workstream
            HeaderView(
                session: session,
                usageStats: usageStats,
                currentTool: currentTool,
                workstream: workstream,
                onTogglePanel: onTogglePanel,
                onOpenSwitcher: onOpenSwitcher,
                onFocusTerminal: { openInITerm() },
                onGoToDashboard: onGoToDashboard,
                onOpenWorkstream: { showingWorkstreamDetail = true }
            )

            Divider()
                .foregroundStyle(Color.panelBorder)

            // Conversation (hero)
            ConversationView(
                transcriptPath: session.transcriptPath,
                sessionId: session.id,
                isSessionActive: session.isActive,
                workStatus: session.workStatus,
                currentTool: currentTool,
                pendingToolName: session.pendingToolName,
                pendingToolInput: session.pendingToolInput,
                isPinned: $isPinned,
                unreadCount: $unreadCount,
                scrollToBottomTrigger: $scrollToBottomTrigger
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Action bar
            actionBar
        }
        .background(Color.backgroundPrimary)
        .onAppear {
            loadUsageStats()
            setupSubscription()
            loadWorkstream()
        }
        .onDisappear {
            transcriptSubscription?.cancel()
        }
        .onChange(of: session.id) { _, _ in
            transcriptSubscription?.cancel()
            loadUsageStats()
            setupSubscription()
            loadWorkstream()
            // Reset scroll state for new session
            isPinned = true
            unreadCount = 0
        }
        .sheet(isPresented: $showingWorkstreamDetail) {
            if let ws = workstream {
                WorkstreamDetailView(
                    workstream: ws,
                    repo: DatabaseManager.shared.fetchRepos().first { $0.id == ws.repoId }
                )
                .frame(minWidth: 600, minHeight: 500)
            }
        }
        .alert("Terminal Not Found", isPresented: $terminalActionFailed) {
            Button("Open New") { TerminalService.shared.focusSession(session) }
            Button("Cancel", role: .cancel) { }
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
            .help(session.isActive ? "Focus terminal" : "Resume in iTerm")

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

            Spacer()

            // Right: Chat scroll + timestamp
            HStack(spacing: 16) {
                // New messages button (only when paused with unread)
                if !isPinned && unreadCount > 0 {
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

    private func loadWorkstream() {
        if let wsId = session.workstreamId {
            workstream = DatabaseManager.shared.fetchWorkstreamWithRelations(id: wsId)
        } else {
            workstream = nil
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
    .frame(width: 800, height: 600)
}
